#!/bin/bash
dockerusername=$(yq '.buildservice.kp_default_repository_username' $HOME/tap-script-eks/tap-values.yaml)
dockerpassword=$(yq '.buildservice.kp_default_repository_password' $HOME/tap-script-eks/tap-values.yaml)
tanzunetusername=$(yq '.buildservice.tanzunet_username' $HOME/tap-script-eks/tap-values.yaml)
tanzunetpassword=$(yq '.buildservice.tanzunet_password' $HOME/tap-script-eks/tap-values.yaml)
dockerhostname=$(yq '.ootb_supply_chain_testing_scanning.registry.server' $HOME/tap-script-eks/tap-values.yaml)
docker login $dockerhostname -u $dockerusername -p $dockerpassword
docker login registry.tanzu.vmware.com -u $tanzunetusername -p $tanzunetpassword
echo "############### Image Copy in progress  ##################"
echo "#################################"
imgpkg copy -b registry.tanzu.vmware.com/tanzu-application-platform/tap-packages:1.1.0 --to-repo $dockerhostname/tap-demo/tap-packages
tanzu secret registry add tap-registry --username $dockerusername --password $dockerpassword --server $dockerhostname --export-to-all-namespaces --yes --namespace tap-install
tanzu package repository add tanzu-tap-repository --url $dockerhostname/tap-demo/tap-packages:1.1.0 --namespace tap-install
tanzu package repository get tanzu-tap-repository --namespace tap-install
tanzu package available list --namespace tap-install
echo "############### TAP 1.1.0 Install   ##################"
tanzu package install tap -p tap.tanzu.vmware.com -v 1.1.0 --values-file $HOME/tap-script/tap-values.yaml -n tap-install
tanzu package installed list -A
reconcilestat=$(tanzu package installed list -A -o json | jq ' .[] | select(.status == "Reconcile failed: Error (see .status.usefulErrorMessage for details)" or .status == "Reconciling")' | jq length | awk '{sum=sum+$0} END{print sum}')
if [ $reconcilestat > '0' ];
    then
	tanzu package installed list -A
	sleep 20m
	echo "################# Wait for 20 minutes #################"
	tanzu package installed list -A
	tanzu package installed get tap -n tap-install
	reconcilestat1=$(tanzu package installed list -A -o json | jq ' .[] | select(.status == "Reconcile failed: Error (see .status.usefulErrorMessage for details)" or .status == "Reconciling")' | jq length | awk '{sum=sum+$0} END{print sum}')
	if [ $reconcilestat1 > '0' ];
	   then
		echo "################### Something is wrong with package install, Check the package status manually ############################"
		echo "################### Exiting #########################"
		exit
	else
		tanzu package installed list -A
		echo "################### Please check if all the packages are succeeded ############################"
		tanzu package installed get tap -n tap-install
	fi
else
	ip=$(kubectl get svc -n tap-gui -o=jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}')
fi
echo "############## Get the package install status #################"
tanzu package installed get tap -n tap-install
tanzu package installed list -A

echo "############# Updating tap-values file with LB ip ################"

ip=$(kubectl get svc -n tap-gui -o=jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}')

echo "################ Cluster supply chain list #####################"
tanzu apps cluster-supply-chain list

echo "################ Developer namespace in tap-install #####################"

cat <<EOF > developer.yaml
apiVersion: v1
kind: Secret
metadata:
  name: tap-registry
  annotations:
    secretgen.carvel.dev/image-pull-secret: ""
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: e30K
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: default
secrets:
  - name: registry-credentials
  - name: tap-registry
imagePullSecrets:
  - name: registry-credentials
  - name: tap-registry
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: default-permit-deliverable
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: deliverable
subjects:
  - kind: ServiceAccount
    name: default
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: default-permit-workload
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: workload
subjects:
  - kind: ServiceAccount
    name: default
---
apiVersion: scanning.apps.tanzu.vmware.com/v1beta1
kind: ScanPolicy
metadata:
  name: scan-policy
spec:
  regoFile: |
    package policies

    default isCompliant = false

    # Accepted Values: "Critical", "High", "Medium", "Low", "Negligible", "UnknownSeverity"
    violatingSeverities := []
    ignoreCVEs := []

    contains(array, elem) = true {
      array[_] = elem
    } else = false { true }

    isSafe(match) {
      fails := contains(violatingSeverities, match.Ratings.Rating[_].Severity)
      not fails
    }

    isSafe(match) {
      ignore := contains(ignoreCVEs, match.Id)
      ignore
    }

    isCompliant = isSafe(input.currentVulnerability)

EOF
kubectl apply -f developer.yaml -n tap-install
kubectl apply -f tekton-pipeline.yaml -n tap-install
cat <<EOF > ootb-supply-chain-basic-values.yaml
grype:
  namespace: tap-install
  targetImagePullSecret: registry-credentials
EOF

echo "################### Installing Grype Scanner ##############################"
tanzu package install grype-scanner --package-name grype.scanning.apps.tanzu.vmware.com --version 1.1.0  --namespace tap-install -f ootb-supply-chain-basic-values.yaml
echo "################### Creating workload ##############################"
tanzu apps workload create tanzu-java-web-app  --git-repo https://github.com/Eknathreddy09/tanzu-java-web-app --git-branch main --type web --label apps.tanzu.vmware.com/has-tests=true --label app.kubernetes.io/part-of=tanzu-java-web-app  --type web -n tap-install --yes
tanzu apps workload get tanzu-java-web-app -n tap-install
echo "#######################################################################"
echo "################ Monitor the progress #################################"
echo "#######################################################################"
tanzu apps workload tail tanzu-java-web-app --since 10m --timestamp -n tap-install