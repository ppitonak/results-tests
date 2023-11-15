#!/bin/bash

set +x

export NAMESPACE="openshift-pipelines"

oc create secret generic tekton-results-postgres -n ${NAMESPACE} --from-literal=POSTGRES_USER=result --from-literal=POSTGRES_PASSWORD=$(openssl rand -base64 20)

echo "Generating TLS certificate"
openssl req -x509 -newkey rsa:4096 -keyout key.pem -out cert.pem -days 365 -nodes \
  -subj "/CN=tekton-results-api-service.${NAMESPACE}.svc.cluster.local" \
  -addext "subjectAltName = DNS:tekton-results-api-service.${NAMESPACE}.svc.cluster.local"

echo "Creating new secret with generated certificate"
oc create secret tls -n ${NAMESPACE} tekton-results-tls --cert=cert.pem --key=key.pem 

# echo "Creating Google Cloud Storage credentials"
#oc create secret generic gcs-credentials --from-file=$HOME/.config/gcloud/application_default_credentials.json -n openshift-pipelines

echo "Creating a PVC for logging"
cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: tekton-logs
  namespace: openshift-pipelines
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 2Gi
EOF

BUCKET_NAME=results-$(date +"%m%d%H%M%S")

echo "Creating TektonResult CR"
cat <<EOF | oc apply -f -
apiVersion: operator.tekton.dev/v1alpha1
kind: TektonResult
metadata:
  name: result
spec:
  targetNamespace: openshift-pipelines
  logs_api: true
  log_level: debug
  db_port: 5432
  db_host: tekton-results-postgres-service.openshift-pipelines.svc.cluster.local
  logging_pvc_name: tekton-logs
  logs_path: /logs
  logs_type: File
  logs_buffer_size: 2097152
  auth_disable: true
  tls_hostname_override: tekton-results-api-service.openshift-pipelines.svc.cluster.local
  db_enable_auto_migration: true
  server_port: 8080
  prometheus_port: 9090
  #gcs_creds_secret_name: gcs-credentials
  #gcs_creds_secret_key: application_default_credentials.json 
  #gcs_bucket_name: $BUCKET_NAME 
EOF

oc create route -n ${NAMESPACE} passthrough tekton-results-api-service --service=tekton-results-api-service --port=8080

oc wait --for=condition=Ready tektoninstallerset -l operator.tekton.dev/type=result

oc get tektonresults.operator.tekton.dev

RESULTS_API=$(oc get route  tekton-results-api-service -n openshift-pipelines --no-headers -o custom-columns=":spec.host"):443

#oc login -u user -p user

export NAMESPACE=results-testing
oc new-project $NAMESPACE

# create one task run and two pipeline runs
oc create -f task-output-image.yaml
tkn tr logs -f --last
tkn tr describe --last -o jsonpath={.metadata.annotations} | jq

oc create -f pipeline.yaml
tkn pipeline start pipeline-results --showlog
tkn pr describe --last -o jsonpath={.metadata.annotations} | jq

echo "opc results list --insecure --addr ${RESULTS_API} ${NAMESPACE}"
opc results list --insecure --addr ${RESULTS_API} ${NAMESPACE}

echo
echo "opc results records list --insecure --addr ${RESULTS_API} results-testing/results/TR_UUID"

echo
echo "opc results records get --insecure --addr ${RESULTS_API} results-testing/results/TR_UUID/records/RECORD_UUID  | yq -r .data.value | base64 -d | yq -P '.'"

echo
echo "opc results logs list --insecure --addr ${RESULTS_API} results-testing/results/TR_UUID"

echo
echo "opc results logs get --insecure --addr ${RESULTS_API} results-testing/results/TR_UUID/logs/RECORD_UUID  | yq -r .data | base64 -d"

export TOKEN2=$(oc create token pipeline)
