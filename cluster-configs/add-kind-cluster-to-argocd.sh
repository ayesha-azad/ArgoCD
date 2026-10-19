#!/bin/bash

# Usage: ./add-kind-cluster-to-argocd.sh <cluster-name> <kube-context> <cluster-port>
# Example: ./add-kind-cluster-to-argocd.sh dev-cluster kind-dev-cluster 6443

CLUSTER_NAME=$1
KUBE_CONTEXT=$2
CLUSTER_PORT=$3

if [ -z "$CLUSTER_NAME" ] || [ -z "$KUBE_CONTEXT" ] || [ -z "$CLUSTER_PORT" ]; then
    echo "Usage: $0 <cluster-name> <kube-context> <cluster-port>"
    echo "Example: $0 dev-cluster kind-dev-cluster 6443"
    exit 1
fi

echo "Adding cluster: $CLUSTER_NAME (port: $CLUSTER_PORT)"

# Step 1: Fix kubeconfig for local access
echo "1. Updating kubeconfig for local access..."
kubectl config set-cluster $KUBE_CONTEXT --server=https://127.0.0.1:$CLUSTER_PORT

# Step 2: Verify local access works
echo "2. Verifying local access..."
if kubectl --context $KUBE_CONTEXT get nodes &>/dev/null; then
    echo "   ✓ Local access working"
else
    echo "   ✗ Local access failed"
    exit 1
fi

# Step 3: Check if secret already exists with correct name
EXISTING_SECRET=$(kubectl get secrets -n argocd -l argocd.argoproj.io/secret-type=cluster -o json | python3 -c "import json,sys,base64; d=json.load(sys.stdin); [print(i['metadata']['name']) for i in d['items'] if i['metadata'].get('labels',{}).get('name') == '$CLUSTER_NAME']" | head -1)

if [ -n "$EXISTING_SECRET" ]; then
    echo "   ✓ Secret already exists for $CLUSTER_NAME"
    SECRET=$EXISTING_SECRET
else
    # Step 4: Register with ArgoCD using --core
    echo "3. Registering cluster with ArgoCD..."
    if ! argocd cluster add $KUBE_CONTEXT --name $CLUSTER_NAME --core -y 2>/dev/null; then
        echo "   argocd cluster add failed, creating secret manually..."
        
        # Get token from the cluster
        TOKEN=$(kubectl --context $KUBE_CONTEXT get secret -n kube-system argocd-manager-long-lived-token -o jsonpath='{.data.token}' 2>/dev/null | base64 -d)
        
        if [ -z "$TOKEN" ]; then
            echo "   Creating fresh service account..."
            argocd cluster add $KUBE_CONTEXT --name $CLUSTER_NAME --core -y 2>&1 | grep -v "level"
            TOKEN=$(kubectl --context $KUBE_CONTEXT get secret -n kube-system argocd-manager-long-lived-token -o jsonpath='{.data.token}' | base64 -d)
        fi
        
        # Create secret manually
        kubectl delete secret -n argocd cluster-$CLUSTER_NAME 2>/dev/null
        kubectl create secret -n argocd generic cluster-$CLUSTER_NAME \
            --from-literal=name=$CLUSTER_NAME \
            --from-literal=server=https://${CLUSTER_NAME}-control-plane:6443 \
            --from-literal=config="{\"bearerToken\":\"$TOKEN\",\"tlsClientConfig\":{\"insecure\":true}}"
        
        kubectl label secret -n argocd cluster-$CLUSTER_NAME \
            argocd.argoproj.io/secret-type=cluster \
            name=$CLUSTER_NAME --overwrite 2>/dev/null
        
        SECRET="cluster-$CLUSTER_NAME"
    fi
    
    # Step 5: Find the secret
    if [ -z "$SECRET" ]; then
        echo "4. Finding cluster secret..."
        SECRET=$(kubectl get secrets -n argocd -l argocd.argoproj.io/secret-type=cluster -o json | \
            python3 -c "import json,sys,base64; d=json.load(sys.stdin); [print(i['metadata']['name']) for i in d['items'] if '127.0.0.1:$CLUSTER_PORT' in base64.b64decode(i['data'].get('server', b'')).decode()]" | head -1)
    fi
    
    if [ -z "$SECRET" ]; then
        echo "   ✗ Could not find secret for cluster $CLUSTER_NAME"
        echo "   Listing available cluster secrets:"
        kubectl get secrets -n argocd -l argocd.argoproj.io/secret-type=cluster
        exit 1
    fi
    
    echo "   Found secret: $SECRET"
    
    # Step 6: Add the name label
    echo "5. Adding name label to secret..."
    kubectl label secret -n argocd $SECRET name=$CLUSTER_NAME --overwrite
    
    # Step 7: Patch secret with internal DNS name (if not already correct)
    echo "6. Patching secret to use internal DNS..."
    CURRENT_SERVER=$(kubectl get secret -n argocd $SECRET -o jsonpath='{.data.server}' | base64 -d)
    EXPECTED_SERVER="https://${CLUSTER_NAME}-control-plane:6443"
    
    if [ "$CURRENT_SERVER" != "$EXPECTED_SERVER" ]; then
        kubectl patch secret -n argocd $SECRET --type='json' \
          -p='[{"op": "replace", "path": "/data/server", "value": "'"$(echo -n "$EXPECTED_SERVER" | base64)"'"}]'
        echo "   Patched from $CURRENT_SERVER to $EXPECTED_SERVER"
    else
        echo "   Server already correct: $CURRENT_SERVER"
    fi
fi

# Step 8: Verify
echo "7. Verifying cluster in ArgoCD..."
sleep 3
argocd cluster list | grep -E "$CLUSTER_NAME|NAME"

echo "✅ Done! Cluster $CLUSTER_NAME is now registered."