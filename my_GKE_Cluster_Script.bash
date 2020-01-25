#Programmer: Amiyn al-Ansare###########################################################################################################
#amiyn@amiyn.com - gitlab.com/amiyn - amiyn.com
#October 16, 2019######################################################################################################################
#####################################GKE CLUSTER WITH SELF-HOSTED GITLAB CI/CI SETUP###################################################
#!/bin/bash -x
#Enable API's and Services

#Store Project Name
export PROJECT_ID=$(gcloud config get-value project)
gcloud compute project-info add-metadata \
--metadata google-compute-default-region=asia-southeast1,google-compute-default-zone=asia-southeast1-a
gcloud config set compute/region asia-southeast1
export REGION=$(gcloud config get-value compute/region)

echo "##############___________________________STATUS: Step 1 ENABLING API'S"
     
gcloud services enable container.googleapis.com
gcloud services enable servicenetworking.googleapis.com
gcloud services enable cloudresourcemanager.googleapis.com
gcloud services enable redis.googleapis.com
echo "##############___________________________STATUS: Ending Step 1" 
#Create Service Accounts and Roles --additinonal configuration may be needed; 
#see https://medium.com/google-cloud/gitlab-continuous-deployment-pipeline-to-gke-with-helm-69d8a15ed910
echo "##############___________________________STATUS: Step 2: Creating I AM service Accounts and Roles"
gcloud iam service-accounts create gitlab-gcs --display-name "GitLab Cloud Storage"
gcloud iam service-accounts keys create --iam-account gitlab-gcs@${PROJECT_ID}.iam.gserviceaccount.com gcs-key.json
gcloud projects add-iam-policy-binding --role roles/storage.admin ${PROJECT_ID} --member=serviceAccount:gitlab-gcs@${PROJECT_ID}.iam.gserviceaccount.com
gcloud projects add-iam-policy-binding --role roles/cloudsql.admin ${PROJECT_ID} --member=serviceAccount:gitlab-gcs@${PROJECT_ID}.iam.gserviceaccount.com
gcloud iam service-accounts create gitlab-gcs --display-name "GitLab Cloud Storage"
gcloud iam service-accounts keys create --iam-account gitlab-gcs@${PROJECT_ID}.iam.gserviceaccount.com gcs-key.json
gcloud projects add-iam-policy-binding --role roles/storage.admin ${PROJECT_ID} --member=serviceAccount:gitlab-gcs@${PROJECT_ID}.iam.gserviceaccount.com
echo "##############___________________________STATUS: Ending Step 2"
#Make Buckets
gsutil mb gs://${PROJECT_ID}-uploads
gsutil mb gs://${PROJECT_ID}-artifacts
gsutil mb gs://${PROJECT_ID}-lfs
gsutil mb gs://${PROJECT_ID}-packages
gsutil mb gs://${PROJECT_ID}-registry
echo "##############___________________________STATUS: Step 3 VPC and IP Addressing"
echo "##############___________________________STATUS: Step 3a Ingress IP"
gcloud compute addresses create gitlab --region asia-southeast1 --description "Gitlab Ingress IP"
gcloud compute addresses create gitlab-sql --global --prefix-length 20 --description="Gitlab Cloud SQL range" --network=default
gcloud services vpc-peerings connect --service servicenetworking.googleapis.com --ranges=gitlab-sql --network default --project ${PROJECT_ID}
gcloud compute networks create gitlab-sql --subnet-mode auto --bgp-routing-mode=global
echo "##############___________________________STATUS: Step 3a.i Creating Firewall Rules VPC Access"
gcloud compute firewall-rules create gitlab-tcp --network gitlab-sql --allow tcp,udp,icmp --source-ranges 10.148.0.0/20
gcloud compute firewall-rules create gitlab-ssh --network gitlab-sql --allow tcp:22,tcp:3389,icmp

#echo "##############___________________________STATUS: Step 3b Creating VPC Network for DB"
#gcloud compute networks create gitlab-sql --subnet-mode auto --bgp-routing-mode=regional

#echo "##############___________________________STATUS: Step 3c Creating Subnet Address Range"
#gcloud compute networks subnets create sea-subnet --region asia-southeast1 --network gitlab-sql --range=10.128.0.0/16 \
#--network gitlb-sql --secondary-range range1=10.148.0.0/20
#echo "##############___________________________STATUS: Step 3d DB IP Address CIDR and Peering"
#gcloud compute addresses gitlab-sql --purpose VPC_PEERING --region asia-southeast1 --prefix-length 20 \
#--addresses range1  --description="Gitlab Cloud SQL range"
#echo "##############____________________________STATUS: Step 3e VPC_PEERING"
#gcloud services vpc-peerings connect --service=servicenetworking.googleapis.com --network=gitlab-sql --address gitlab-sql


#echo "##########################Creating Network and Subnet"
#Create Network and Subnet and Firewall
#echo "##############___________________________STATUS: Step 3c Creating VPC Network for DB"
#gcloud compute networks create gitlab-sql --subnet-mode auto --bgp-routing-mode=regional
#echo "##########################Creating IP Adddress Ranges"
#gcloud compute addresses create gitlab --region asia-southeast1 --purpose=VPC_PEERING --addresses=10.148.0.0/20 --prefix-length=20 --description=Gitlab Cloud SQL range --network=gitlab-sql
#echo "##############___________________________STATUS: Step 3d Creating Subnet in Regional IP Address Range"
#gcloud compute networks subnets create sea-subnet --network gitlab-sql --range 10.148.0.0/20 --secondary-range range2=10.152.0.0/20 --region asia-southeast1
#echo "##############___________________________STATUS: Step 3e Creating Firewall Rules for com ports"
#gcloud compute firewall-rules create gitlab-tcp --network gitlab-sql --allow tcp,udp,icmp --source-ranges 10.148.0.0/20,10.152.0.0/20
#gcloud compute firewall-rules create gitlab-ssh --network gitlab-sql --allow tcp:22,tcp:3389,icmp


echo "##############___________________________STATUS: Ending Step 3"

#Create DB Instance Manualy Add to Default Network and Disable Public IP Addressing
gcloud sql instances create gitlab-db --database-version=POSTGRES_11 --tier db-f1-micro
#Create User/Password
export PASSWORD=$(openssl rand -base64 18)
gcloud sql users create gitlab --instance gitlab-db --password ${PASSWORD}

#Create Database
gcloud sql databases create --instance gitlab-db gitlabhq_production

#Redis
gcloud redis instances create gitlab --size=2 --region=asia-southeast1 --zone=asia-southeast1-a --tier basic

#Build Cluster
gcloud container clusters create gitlab --machine-type g1-small --zone asia-southeast1-a --enable-ip-alias \
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
cat > rails.yaml <<EOF
provider: Google
google_project: ${PROJECT_ID}
google_client_email: gitlab-gcs@${PROJECT_ID}.iam.gserviceaccount.com
google_json_key_string: '$(cat gcs-key.json)'
EOF
kubectl apply -f rails.yaml
kubectl create secret generic gitlab-rails-storage --from-file=connection=rails.yaml

#CONFIGURE GITLAB ENVIRONMENT
wget https://storage.googleapis.com/kubernetes-helm/helm-v2.12.3-linux-amd64.tar.gz
tar zxfv helm-v2.12.3-linux-amd64.tar.gz
cp linux-amd64/helm .

kubectl create serviceaccount tiller --namespace kube-system
kubectl create clusterrolebinding tiller-admin-binding --clusterrole=cluster-admin --serviceaccount=kube-system:tiller

#Start Helm Tiller
helm init --service-account=tiller
helm repo update
helm version

#Get the Gitlab Helm Charts
wget https://raw.githubusercontent.com/terraform-google-modules/terraform-google-gke-gitlab/master/values.yaml.tpl

#Create Config File for Helm Charts
export PROJECT_ID=$(gcloud config get-value project)
export INGRESS_IP=$(gcloud compute addresses describe gitlab \
--region ${REGION} --flatten address)
export DB_PRIVATE_IP=$(gcloud sql instances describe gitlab-db \
--format 'value(ipAddresses[0].ipAddress)')
export REDIS_PRIVATE_IP=$(gcloud redis instances describe gitlab \
--region=${REGION} --format 'value(host)')
export CERT_MANAGER_EMAIL=$(gcloud config get-value account)

cat values.yaml.tpl | envsubst > values.yaml
#Install Helm Charts
helm repo add gitlab https://charts.gitlab.io/
helm install -f values.yaml -n gitlab gitlab/gitlab

#Set-up Monitoring
git clone https://github.com/stackdriver/stackdriver-prometheus-sidecar
cd stackdriver-prometheus-sidecar/kube/full

export KUBE_NAMESPACE=default
export KUBE_CLUSTER=gitlab
export GCP_REGION=asia-southeast1
export GCP_PROJECT=$(gcloud config get-value project)
export SIDECAR_IMAGE_TAG=release-0.4.2


sh deploy.sh


#Get Gitlab Details
export GITLAB_HOSTNAME=$(kubectl get ingresses.extensions gitlab-unicorn -o jsonpath='{.spec.rules[0].host}')
echo "Your GitLab URL is: https://${GITLAB_HOSTNAME}"echo "Your GitLab URL is: https://${GITLAB_HOSTNAME}"
kubectl get secret gitlab-gitlab-initial-root-password -o go-template='{{.data.password}}' | base64 -d && echo
kubectl get pods
