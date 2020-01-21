#Programmer: Amiyn al-Ansare###########################################################################################################
#amiyn@amiyn.com - gitlab.com/amiyn - amiyn.com
#October 16, 2019######################################################################################################################
#####################################GKE CLUSTER WITH SELF-HOSTED GITLAB CI/CI SETUP###################################################
#!/bin/bash -x
#Enable API's and Services

gcloud services enable container.googleapis.com
gcloud services enable servicenetworking.googleapis.com
gcloud services enable cloudresourcemanager.googleapis.com
gcloud services enable redis.googleapis.com
	   
#Create Service Accounts and Roles --additinonal configuration may be needed; 
#see https://medium.com/google-cloud/gitlab-continuous-deployment-pipeline-to-gke-with-helm-69d8a15ed910
export PROJECT_ID=$(gcloud config get-value project)
gcloud iam service-accounts create gitlab-gcs --display-name "GitLab Cloud Storage"
gcloud iam service-accounts keys create --iam-account gitlab-gcs@${PROJECT_ID}.iam.gserviceaccount.com gcs-key.json
gcloud projects add-iam-policy-binding --role roles/storage.admin ${PROJECT_ID} --member=serviceAccount:gitlab-gcs@${PROJECT_ID}.iam.gserviceaccount.com
gcloud projects add-iam-policy-binding --role roles/cloudsql.admin ${PROJECT_ID} --member=serviceAccount:gitlab-gcs@${PROJECT_ID}.iam.gserviceaccount.com
gcloud iam service-accounts create gitlab-gcs --display-name "GitLab Cloud Storage"
gcloud iam service-accounts keys create --iam-account gitlab-gcs@${PROJECT_ID}.iam.gserviceaccount.com gcs-key.json
gcloud projects add-iam-policy-binding --role roles/storage.admin ${PROJECT_ID} --member=serviceAccount:gitlab-gcs@${PROJECT_ID}.iam.gserviceaccount.com

#Make Buckets
export PROJECT_ID=$(gcloud config get-value project)
gsutil mb gs://${PROJECT_ID}-uploads
gsutil mb gs://${PROJECT_ID}-artifacts
gsutil mb gs://${PROJECT_ID}-lfs
gsutil mb gs://${PROJECT_ID}-packages
gsutil mb gs://${PROJECT_ID}-registry

#Generate Ingress IP
gcloud compute addresses create gitlab --region us-central1 --description "Gitlab Ingress IP"

#Database IP Configuration
export PROJECT_ID=$(gcloud config get-value project)
gcloud compute addresses create gitlab-sql --global --prefix-length 20 --description="Gitlab Cloud SQL range" --network=default
gcloud services vpc-peerings connect --service servicenetworking.googleapis.com --ranges=gitlab-sql --network default --project amiyndevops

#Create DB Instance
gcloud sql instances create gitlab-db --database-version=POSTGRES_11 --cpu=2 --memory=4 --region=us-central1-a --authorized-networks default --no-aasign_ip

#Create User/Password
export PASSWORD=$(openssl rand -base64 18)
gcloud sql users create gitlab --instance gitlab-db --password ${PASSWORD}

#Create Database
gcloud sql databases create --instance gitlab-db gitlabhq_production

#Redis
gcloud redis instances create gitlab --size=2 --region=us-central1 --zone=us-central1-a --tier standard

#Build Cluster
gcloud container clusters create gitlab --machine-type g1-small --zone us-central1-a --enable-ip-alias \
--enable-autoscaling --min-nodes 3 --max-nodes 3

#Create Cloud Storgage
cat > pd-ssd-storage.yaml <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: pd-ssd
provisioner: kubernetes.io/gce-pd
parameters:
  type: pd-ssd
EOF

kubectl apply -f pd-ssd-storage.yaml

# Create Password Secrets
 kubectl create secret generic gitlab-pg --from-literal=password=${PASSWORD}

#Create Rails Storage Secrets
export PROJECT_ID=$(gcloud config get-value project)

cat > rails.yaml <<EOF
provider: Google
google_project: ${PROJECT_ID}
google_client_email: gitlab-gcs@${PROJECT_ID}.iam.gserviceaccount.com
google_json_key_string: '$(cat gcs-key.json)'
EOF
kubectl create secret generic gitlab-rails-storage --from-file=connection=rails.yaml

#CONFIGURE GITLAB ENVIRONMENT
wget https://storage.googleapis.com/kubernetes-helm/helm-v2.12.3-linux-amd64.tar.gz
tar zxfv helm-v2.12.3-linux-amd64.tar.gz
cp linux-amd64/helm .

kubectl create serviceaccount tiller --namespace kube-system
kubectl create clusterrolebinding tiller-admin-binding --clusterrole=cluster-admin --serviceaccount=kube-system:tiller

#Start Helm Tiller
./helm init --service-account=tiller
./helm update
./helm version

#Get the Gitlab Helm Charts
wget https://raw.githubusercontent.com/terraform-google-modules/terraform-google-gke-gitlab/master/values.yaml.tpl

#Create Config File for Helm Charts
export PROJECT_ID=$(gcloud config get-value project)
export INGRESS_IP=$(gcloud compute addresses describe gitlab --region us-central1 --format 'value(address)')
export DB_PRIVATE_IP=$(gcloud sql instances describe gitlab-db --format 'value(ipAddresses[0].ipAddress)')
export REDIS_PRIVATE_IP=$(gcloud redis instances describe gitlab --region=us-central1  --format 'value(host)')
export CERT_MANAGER_EMAIL=$(gcloud config get-value account)

cat values.yaml.tpl | envsubst > values.yaml

#Install Helm Charts
./helm repo add gitlab https://charts.gitlab.io/
./helm install -f values.yaml -n gitlab gitlab/gitlab

#Set-up Monitoring
git clone https://github.com/stackdriver/stackdriver-prometheus-sidecar
cd stackdriver-prometheus-sidecar/kube/full

export KUBE_NAMESPACE=default
export GCP_REGION=us-central1
export GCP_PROJECT=$(gcloud config get-value project)
export SIDECAR_IMAGE_TAG=release-0.4.2

./deploy.sh


#Get Gitlab Details
export GITLAB_HOSTNAME=$(kubectl get ingresses.extensions gitlab-unicorn -o jsonpath='{.spec.rules[0].host}')
echo "Your GitLab URL is: https://${GITLAB_HOSTNAME}"
kubectl get secret gitlab-gitlab-initial-root-password -o go-template='{{.data.password}}' | base64 -d && echo
kubectl get pods
