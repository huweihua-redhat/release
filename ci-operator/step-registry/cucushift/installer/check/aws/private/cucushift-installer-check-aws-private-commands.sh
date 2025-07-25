#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=101
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-post-check-status.txt"' EXIT TERM

REGION="${LEASED_RESOURCE}"
INFRA_ID=$(jq -r '.infraID' ${SHARED_DIR}/metadata.json)
CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

ret=0

#Check there's no external load balancer created in this cluster
CLUSTER_LB_LIST=$(mktemp)

for lb in $(aws --region ${REGION} elbv2 describe-load-balancers | jq -r '.LoadBalancers[].LoadBalancerArn'); do
    aws --region ${REGION} elbv2 describe-tags --resource-arns "$lb" | jq --arg infra "kubernetes.io/cluster/${INFRA_ID}" -ce '.TagDescriptions[].Tags[] | select( .Key == "\($infra)")' && echo "$lb" >> "${CLUSTER_LB_LIST}"
done

for cluster_lb in $(cat $CLUSTER_LB_LIST); do 
    LB_TYPE=$(aws --region ${REGION} elbv2 describe-load-balancers --load-balancer-arns ${cluster_lb} | jq -r '.LoadBalancers[].Scheme')
    if [[ "${LB_TYPE}" == "internal" ]]; then
        echo "Pass: LB ${cluster_lb} is internal."
    else
        echo "Error: LB ${cluster_lb} is not internal, the LB type is ${LB_TYPE}"
        ret=$((ret + 1))
    fi
done


PUBLIC_ZONE_ID=$(aws route53 list-hosted-zones-by-name | jq --arg name "${BASE_DOMAIN}." -r '.HostedZones | .[] | select(.Name=="\($name)") | .Id' | awk -F / '{printf $3}')

if [[ -n "${PUBLIC_ZONE_ID}" ]]; then
    PUBLIC_RECORD_SETS=$(aws route53 list-resource-record-sets --hosted-zone-id=${PUBLIC_ZONE_ID} --output json | jq '.ResourceRecordSets[].Name' |grep "${CLUSTER_NAME}.${BASE_DOMAIN}" || true)

    if [[ -n "${PUBLIC_RECORD_SETS}" ]]; then
        echo "Error: there's public Route 53 DNS records that matches this cluster"
	echo "${PUBLIC_RECORD_SETS}"
	ret=$((ret + 1))
    else
        echo "PASS: no public Route 53 DNS records that matches this cluster"
    fi
else
    echo "WARN: no valid PUBLIC_ZONE_ID found for this base domain ${BASE_DOMAIN}, skip the public DNS checking"
fi

exit $ret
