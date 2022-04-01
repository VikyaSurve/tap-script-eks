#!/bin/bash
echo "############################ Keep Azure container registry credentials handy ######################"
echo "#####################################################################################################"
echo "##### Pivnet Token: login to tanzu network, click on your username in top right corner of the page > select Edit Profile, scroll down and click on Request New Refresh Token ######"
read -p "Enter the Pivnet token: " pivnettoken
read -p "Enter the Tanzu network username: " tanzunetusername
read -p "Enter the Tanzu network password: " tanzunetpassword
read -p "Enter the Ingress Domain for CNRS: " cnrsdomain
read -p "Enter the domain name for Learning center: " domainname
read -p "Enter github token (to be collected from Githubportal): " githubtoken
read -p "Do you want to use existing EKS cluster or create a new one? Type "N" for new, "E" for existing: " clusterconnect
read -p "Enter ACR Login server Name: " dockerhostname
read -p "Enter ACR Login server username: " dockerusername
read -p "Enter ACR Login server password: " dockerpassword
echo "#########################################"
echo "#########################################"
echo "Installing AWS cli"
echo "#########################################"
echo "#########################################"
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
sudo apt install unzip
unzip awscliv2.zip
sudo ./aws/install
./aws/install -i /usr/local/aws-cli -b /usr/local/bin
echo "#########################################"
echo "AWS CLI version"
echo "#########################################"
aws --version
echo "#########################################"
echo "############# Provide AWS access key and secrets  ##########################"
aws configure
read -p "Enter AWS session token: " aws_token
aws configure set aws_session_token $aws_token
echo "############ Install Kubectl #######################"
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
echo "############  Kubectl Version #######################"
kubectl version
if [ "$clusterconnect" == "N" ];
then
	read -p "Enter the region: " region

echo "################## Creating IAM Roles for EKS Cluster and nodes ###################### "
cat <<EOF > cluster-role-trust-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "eks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
cat <<EOF > node-role-trust-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
aws iam create-role --role-name tap-EKSClusterRole --assume-role-policy-document file://"cluster-role-trust-policy.json"
aws iam attach-role-policy --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy --role-name tap-EKSClusterRole
aws iam create-role --role-name tap-EKSNodeRole --assume-role-policy-document file://"node-role-trust-policy.json"
aws iam attach-role-policy --policy-arn arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy --role-name tap-EKSNodeRole
aws iam attach-role-policy --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly --role-name tap-EKSNodeRole
aws iam attach-role-policy --policy-arn arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy --role-name tap-EKSNodeRole

echo "########################### Creating VPC Stacks through cloud formation ##############################"
aws cloudformation create-stack --region $region --stack-name tap-demo-vpc-stack --template-url https://amazon-eks.s3.us-west-2.amazonaws.com/cloudformation/2020-10-29/amazon-eks-vpc-private-subnets.yaml
echo "############## Waiting for VPC stack to get created ###################"
echo "############## Paused for 5 mins ##########################"
sleep 5m
pubsubnet1=$(aws ec2 describe-subnets --filters Name=tag:Name,Values=tap-demo-vpc-stack-PublicSubnet01 --query Subnets[0].SubnetId --output text)
pubsubnet2=$(aws ec2 describe-subnets --filters Name=tag:Name,Values=tap-demo-vpc-stack-PublicSubnet02 --query Subnets[0].SubnetId --output text)
rolearn=$(aws iam get-role --role-name tap-EKSClusterRole --query Role.Arn --output text)
sgid=$(aws ec2 describe-security-groups --filters Name=description,Values="Cluster communication with worker nodes" --query SecurityGroups[0].GroupId --output text)

echo "########################## Creating EKS Cluster ########################################"

ekscreatecluster=$(aws eks create-cluster --region $region --name tap-demo-ekscluster --kubernetes-version 1.21 --role-arn $rolearn --resources-vpc-config subnetIds=$pubsubnet1,$pubsubnet2,securityGroupIds=$sgid)

echo "############## Waiting for EKS cluster to get created ###################"
echo "############## Paused for 15 mins ###############################"
sleep 15m
aws eks update-kubeconfig --region $region --name tap-demo-ekscluster

rolenodearn=$(aws iam get-role --role-name tap-EKSNodeRole --query Role.Arn --output text)
echo "######################### Creating Node Group ###########################"
aws eks create-nodegroup --cluster-name tap-demo-ekscluster --nodegroup-name tap-demo-eksclusterng --node-role $rolenodearn --instance-types t2.2xlarge --scaling-config minSize=2,maxSize=3,desiredSize=3 --disk-size 40  --subnets $pubsubnet1

echo "############## Waiting for Node groups to get created ###################"
echo "############### Paused for 10 mins ################################"
sleep 10m

else
        read -p "Provide the EKS cluster : " eksclustername
        read -p "Provide the EKS cluster region: " eksclusterregion
        aws eks update-kubeconfig --region $eksclusterregion --name $eksclustername
fi
echo "################ Prepare Tap values file ##################"
cat <<EOF > tap-values.yaml
profile: full
ceip_policy_disclosed: true # Installation fails if this is set to 'false'
buildservice:
  kp_default_repository: "$dockerhostname/build-service" # Replace the project id with yours. In my case eknath-se is the project ID
  kp_default_repository_username: $dockerusername
  kp_default_repository_password: $dockerpassword
  tanzunet_username: "$tanzunetusername" # Provide the Tanzu network user name
  tanzunet_password: "$tanzunetpassword" # Provide the Tanzu network password
  descriptor_name: "tap-1.0.0-full"
  enable_automatic_dependency_updates: true
supply_chain: testing_scanning
ootb_supply_chain_testing_scanning:
  registry:
    server: "$dockerhostname"
    repository: "supply-chain" # Replace the project id with yours. In my case eknath-se is the project ID
  gitops:
    ssh_secret: ""
  cluster_builder: default
  service_account: default
cnrs:
  domain_name: $cnrsdomain

learningcenter:
  ingressDomain: "$domainname" # Provide a Domain Name

metadata_store:
  app_service_type: LoadBalancer # (optional) Defaults to LoadBalancer. Change to NodePort for distributions that don't support LoadBalancer
grype:
  namespace: "tap-install" # (optional) Defaults to default namespace.
  targetImagePullSecret: "registry-credentials"
contour:
  envoy:
    service:
      type: LoadBalancer
tap_gui:
  service_type: LoadBalancer # NodePort for distributions that don't support LoadBalancer
  app_config:
    app:
      baseUrl: http://tap-gui.$cnrsdomain
    integrations:
      github: # Other integrations available see NOTE below
        - host: github.com
          token: $githubtoken  # Create a token in github
    catalog:
      locations:
        - type: url
          target: https://github.com/Eknathreddy09/tanzu-java-web-app/blob/main/catalog/catalog-info.yaml
    backend:
      baseUrl: http://tap-gui.$cnrsdomain
      cors:
        origin: http://tap-gui.$cnrsdomain
EOF
echo "#####################################################################################################"
echo "########### Creating Secrets in tap-install namespace  #############"
kubectl create ns tap-install
kubectl create secret docker-registry registry-credentials --docker-server=$dockerhostname --docker-username=$dockerusername --docker-password=$dockerpassword -n tap-install
kubectl create secret docker-registry image-secret --docker-server=$dockerhostname --docker-username=$dockerusername --docker-password=$dockerpassword -n tap-install
echo "############# Installing Pivnet ###########"
wget https://github.com/pivotal-cf/pivnet-cli/releases/download/v3.0.1/pivnet-linux-amd64-3.0.1
chmod +x pivnet-linux-amd64-3.0.1
sudo mv pivnet-linux-amd64-3.0.1 /usr/local/bin/pivnet

echo "########## Installing Tanzu CLI  #############"
pivnet login --api-token=${pivnettoken}
pivnet download-product-files --product-slug='tanzu-cluster-essentials' --release-version='1.0.0' --product-file-id=1105818
mkdir $HOME/tanzu-cluster-essentials
tar -xvf tanzu-cluster-essentials-linux-amd64-1.0.0.tgz -C $HOME/tanzu-cluster-essentials
export INSTALL_BUNDLE=registry.tanzu.vmware.com/tanzu-cluster-essentials/cluster-essentials-bundle@sha256:82dfaf70656b54dcba0d4def85ccae1578ff27054e7533d08320244af7fb0343
export INSTALL_REGISTRY_HOSTNAME=registry.tanzu.vmware.com
export INSTALL_REGISTRY_USERNAME=$tanzunetusername
export INSTALL_REGISTRY_PASSWORD=$tanzunetpassword
cd $HOME/tanzu-cluster-essentials
./install.sh
echo "######## Installing Kapp ###########"
sudo cp $HOME/tanzu-cluster-essentials/kapp /usr/local/bin/kapp
kapp version
echo "######## Installing Imgpkg ###########"
sudo cp $HOME/tanzu-cluster-essentials/imgpkg /usr/local/bin/imgpkg
imgpkg version
echo "#################################"
pivnet download-product-files --product-slug='tanzu-application-platform' --release-version='1.0.2' --product-file-id=1156168
mkdir $HOME/tanzu
tar -xvf tanzu-framework-linux-amd64.tar -C $HOME/tanzu
export TANZU_CLI_NO_INIT=true
cd $HOME/tanzu
sudo install cli/core/v0.11.1/tanzu-core-linux_amd64 /usr/local/bin/tanzu
tanzu version
tanzu plugin install --local cli all
tanzu plugin list
echo "######### Installing Docker ############"
sudo apt-get update
sudo apt-get install  ca-certificates curl  gnupg  lsb-release
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
sudo apt-get install docker-ce docker-ce-cli containerd.io -y
sudo usermod -aG docker $USER
echo "####### Install tap-registry in all namespaces  ###########"
sudo apt-get install jq -y
echo "#####################################################################################################"
sudo docker login $dockerhostname -u $dockerusername -p $dockerpassword
sudo docker login registry.tanzu.vmware.com -u $tanzunetusername -p $tanzunetpassword
sudo imgpkg copy -b registry.tanzu.vmware.com/tanzu-application-platform/tap-packages:1.0.2 --to-repo $dockerhostname/tap-demo/tap-packages
kubectl create ns tap-install
tanzu secret registry add tap-registry --username $dockerusername --password $dockerpassword --server $dockerhostname --export-to-all-namespaces --yes --namespace tap-install
tanzu package repository add tanzu-tap-repository --url $dockerhostname/tap-demo/tap-packages:1.0.2 --namespace tap-install
tanzu package repository get tanzu-tap-repository --namespace tap-install
tanzu package available list --namespace tap-install

echo "########### Rebooting #############"
sudo reboot
