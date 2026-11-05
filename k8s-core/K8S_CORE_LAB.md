# Kubernetes Building Blocks Lab

**Goal:** add the five building blocks to our booking app, one step each, in a new namespace `k8s-lab`:
ConfigMap & Secret → Ingress → PersistentVolume → RBAC → NetworkPolicy.

**You need:** `kubectl` and `helm` working against a cluster (EKS, minikube or kind).
Run every command from the **`k8s-core/`** folder.

```
k8s-core/
├── K8S_CORE_LAB.md               <- this guide
├── K8s_Building_Blocks.pptx
├── 00-namespace.yaml
├── 01-config/         configmap.yaml  secret.yaml  booking.yaml
├── 02-ingress/        web.yaml  ingress.yaml
├── 03-storage/        pvc.yaml  storageclass-gp3.yaml  pv-pvc-static.yaml  notes.yaml
├── 04-rbac/           rbac.yaml
└── 05-network-policy/ deny-all.yaml  allow.yaml
```

| Step | Needs on EKS | Needs on minikube |
|---|---|---|
| 3 Ingress | Nothing extra (Traefik gets an AWS ELB) | `minikube tunnel`, or port-forward |
| 4 Storage | EBS CSI driver add-on (or use the static option) | Nothing (default class `standard`) |
| 6 Network policy | VPC CNI with network policy turned on | `minikube start --cni=calico` |

---

## Step 1 – Namespace, ConfigMap, Secret and the booking app

```bash
kubectl apply -f 00-namespace.yaml
kubectl apply -f 01-config/configmap.yaml -f 01-config/secret.yaml     # settings first…
kubectl apply -f 01-config/booking.yaml                                # …then the app that reads them
kubectl get configmap,secret,deploy,svc,pods -n k8s-lab
```

Wait until the `booking` pod is `Running`.

---

## Step 2 – See how the pod got its settings

**As environment variables** (from `envFrom`):

```bash
kubectl exec -n k8s-lab deploy/booking -- env | grep -E "APP_ENV|LOG_LEVEL|DB_"
```

Expect `APP_ENV=dev`, `LOG_LEVEL=INFO`, `DB_USER=booking`, `DB_PASSWORD=Demo-only-123`.

**As files** (from the volume):

```bash
kubectl exec -n k8s-lab deploy/booking -- ls /config
kubectl exec -n k8s-lab deploy/booking -- cat /config/app.properties
```

**A Secret is only base64:**

```bash
kubectl get secret booking-secret -n k8s-lab -o jsonpath="{.data.DB_PASSWORD}"
```

| Shell | Decode it |
|---|---|
| bash / Git Bash | `kubectl get secret booking-secret -n k8s-lab -o jsonpath="{.data.DB_PASSWORD}" \| base64 -d` |
| PowerShell | `[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String((kubectl get secret booking-secret -n k8s-lab -o jsonpath="{.data.DB_PASSWORD}")))` |

**Change a setting – files update, env vars don't:**

```bash
kubectl patch configmap booking-config -n k8s-lab --type merge -p "{\"data\":{\"LOG_LEVEL\":\"DEBUG\"}}"
# wait ~1 minute
kubectl exec -n k8s-lab deploy/booking -- cat /config/LOG_LEVEL          # DEBUG  (file updated)
kubectl exec -n k8s-lab deploy/booking -- printenv LOG_LEVEL             # INFO   (env var did not)
kubectl rollout restart deploy/booking -n k8s-lab                        # new pod reads the new value
```

---

## Step 3 – Ingress: one entry point for two apps

**3a. Install an Ingress controller (Traefik) with Helm:**

```bash
helm repo add traefik https://traefik.github.io/charts
helm repo update
helm install traefik traefik/traefik -n traefik --create-namespace
kubectl get pods,svc -n traefik
kubectl get ingressclass                   # shows "traefik"
```

> We use Traefik because the community **ingress-nginx** controller was retired in March 2026.
> The Ingress YAML is the same for any controller; only `ingressClassName` changes.

**3b. Add the second app and the Ingress rules:**

```bash
kubectl apply -f 02-ingress/
kubectl get ingress -n k8s-lab
kubectl describe ingress booking-ingress -n k8s-lab
```

**3c. Open it.** Find the address:

| Cluster | Address |
|---|---|
| EKS | `kubectl get svc traefik -n traefik` → EXTERNAL-IP (an `elb.amazonaws.com` name, ready in 1–3 min) |
| minikube | run `minikube tunnel` in another terminal, then the EXTERNAL-IP |
| Any cluster | `kubectl port-forward -n traefik svc/traefik 8000:80` → use `localhost:8000` |

| URL | Goes to |
|---|---|
| `http://<address>/` | `web` → nginx welcome page |
| `http://<address>/mahaLogin/` | `booking` → our login page |

One load balancer, two apps, routed by path. The `booking` Service is only `ClusterIP`: no NodePort, no ELB of its own.

---

## Step 4 – Persistent storage

**4a. Is there a default StorageClass?**

```bash
kubectl get sc
```

| You see | Do |
|---|---|
| A class marked `(default)` | Use **Option A** below |
| EKS, no default, EBS CSI driver installed | `kubectl apply -f 03-storage/storageclass-gp3.yaml`, then Option A |
| EKS, no EBS CSI driver | Install it (box below), or use **Option B** |

<details>
<summary>EKS: install the EBS CSI driver add-on</summary>

```bash
CLUSTER=<your-cluster-name>
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
eksctl utils associate-iam-oidc-provider --cluster $CLUSTER --approve
eksctl create iamserviceaccount --cluster $CLUSTER --namespace kube-system \
  --name ebs-csi-controller-sa --role-name AmazonEKS_EBS_CSI_DriverRole --role-only \
  --attach-policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy --approve
eksctl create addon --cluster $CLUSTER --name aws-ebs-csi-driver \
  --service-account-role-arn arn:aws:iam::$ACCOUNT:role/AmazonEKS_EBS_CSI_DriverRole --force
kubectl apply -f 03-storage/storageclass-gp3.yaml
```
</details>

**4b. Create the claim – pick ONE option:**

```bash
kubectl apply -f 03-storage/pvc.yaml              # Option A: dynamic (StorageClass makes the disk)
kubectl apply -f 03-storage/pv-pvc-static.yaml    # Option B: static hostPath PV (learning only)
```

**4c. Start the app and write a file to the volume:**

```bash
kubectl apply -f 03-storage/notes.yaml
kubectl get pvc,pv -n k8s-lab                     # PVC STATUS: Bound
kubectl exec -n k8s-lab deploy/notes -- sh -c "echo 'Hello from a PersistentVolume' > /usr/share/nginx/html/index.html"
kubectl exec -n k8s-lab deploy/notes -- cat /usr/share/nginx/html/index.html
```

**4d. Delete the pod and check the data survived:**

```bash
kubectl delete pod -n k8s-lab -l app=notes
kubectl rollout status deploy/notes -n k8s-lab
kubectl exec -n k8s-lab deploy/notes -- cat /usr/share/nginx/html/index.html     # still there
```

> With `WaitForFirstConsumer` the PVC stays `Pending` until the notes pod starts – that is normal.
> `kubectl describe pvc notes-data -n k8s-lab` explains any other `Pending`.

---

## Step 5 – RBAC: a read-only identity

```bash
kubectl apply -f 04-rbac/rbac.yaml
kubectl get sa,role,rolebinding -n k8s-lab
```

Test what the `viewer` ServiceAccount may do (`--as` = pretend to be it):

```bash
W=system:serviceaccount:k8s-lab:viewer
kubectl auth can-i list pods      -n k8s-lab --as=$W     # yes
kubectl auth can-i get pods/log   -n k8s-lab --as=$W     # yes
kubectl auth can-i delete pods    -n k8s-lab --as=$W     # no
kubectl auth can-i get secrets    -n k8s-lab --as=$W     # no
kubectl auth can-i list pods      -n default --as=$W     # no  (other namespace)
kubectl get pods -n k8s-lab --as=$W                       # works
kubectl delete pod -n k8s-lab -l app=web --as=$W          # Forbidden
```

(PowerShell: `$W = "system:serviceaccount:k8s-lab:viewer"`, then use `--as=$W` the same way.)

Everything the Role does not list is denied. That is least privilege.

---

## Step 6 – Network policies: a firewall for pods

**6a. Make sure your cluster enforces them:**

| Cluster | Turn it on |
|---|---|
| EKS (VPC CNI ≥ 1.14 as an EKS add-on) | `aws eks update-addon --cluster-name <cluster> --addon-name vpc-cni --configuration-values "{\"enableNetworkPolicy\":\"true\"}"` |
| minikube | `minikube start --cni=calico` (new cluster) |
| kind | Install Calico or Cilium |

> If the CNI does not enforce NetworkPolicy, the YAML is accepted but **silently ignored** – the "timeout" tests below will
> still succeed. That itself is worth seeing once.

**6b. Before any policy – everyone can talk to booking:**

```bash
kubectl run t1 --rm -it --restart=Never -n k8s-lab --image=busybox:1.36 -- wget -qO- -T 3 booking:8080 | head -3
```

**6c. Deny everything, then test again:**

```bash
kubectl apply -f 05-network-policy/deny-all.yaml
kubectl run t2 --rm -it --restart=Never -n k8s-lab --image=busybox:1.36 -- wget -qO- -T 3 booking:8080
# wget: download timed out
```

The Ingress URL from step 3 now also fails – Traefik is blocked too.

**6d. Allow the frontend and Traefik:**

```bash
kubectl apply -f 05-network-policy/allow.yaml
kubectl get networkpolicy -n k8s-lab

kubectl run t3 --rm -it --restart=Never -n k8s-lab --image=busybox:1.36 -l role=frontend -- wget -qO- -T 3 booking:8080 | head -3
# works: the pod has role=frontend

kubectl run t4 --rm -it --restart=Never -n k8s-lab --image=busybox:1.36 -- wget -qO- -T 3 booking:8080
# still times out: no label

kubectl run t5 --rm -it --restart=Never -n k8s-lab --image=busybox:1.36 -l role=frontend -- wget -qO- -T 3 web
# times out: role=frontend may reach booking, not web
```

The Ingress URLs (`/` and `/mahaLogin/`) work again, because `allow-from-traefik` lets the controller in.

| Who → where | After allow.yaml |
|---|---|
| Traefik → booking, web | Allowed |
| `role=frontend` pod → booking:8080 | Allowed |
| `role=frontend` pod → web | Blocked |
| Any other pod → anything in k8s-lab | Blocked |

---

## Step 7 – Clean up

```bash
kubectl delete namespace k8s-lab               # removes every lab object (and the dynamic EBS disk)
kubectl delete pv notes-pv                     # only if you used Option B (PVs are not namespaced)
helm uninstall traefik -n traefik              # removes the AWS ELB – it is billed hourly
kubectl delete namespace traefik
```

---

## Troubleshooting

| Problem | Cause | Fix |
|---|---|---|
| `kubectl get ingress` shows no ADDRESS | No controller, or wrong `ingressClassName` | `kubectl get ingressclass`; install Traefik (step 3a) |
| Traefik EXTERNAL-IP `<pending>` | EKS: subnet tags; minikube: no tunnel | `kubectl describe svc traefik -n traefik`; run `minikube tunnel` |
| `/mahaLogin/` gives 404 | Path typo, or booking pod not ready | `kubectl describe ingress booking-ingress -n k8s-lab`; `kubectl get pods -n k8s-lab` |
| PVC stuck `Pending` | No default StorageClass or no CSI driver | Step 4a; `kubectl describe pvc notes-data -n k8s-lab` |
| notes pod `ContainerCreating` for minutes | EBS volume attaching, or in another zone | Wait; `kubectl describe pod -n k8s-lab -l app=notes` |
| Env var did not change after editing the ConfigMap | Env vars are read only at start | `kubectl rollout restart deploy/booking -n k8s-lab` |
| `can-i` says yes for everything | You forgot `--as`, so it checks your own admin user | Add `--as=system:serviceaccount:k8s-lab:viewer` |
| Network policy has no effect | CNI does not enforce policies | Step 6a |
| Ingress broke after deny-all | Traefik blocked too | `kubectl apply -f 05-network-policy/allow.yaml` |

---

## Homework

1. Put `APP_COLOR` in the ConfigMap and show it with `kubectl exec … printenv APP_COLOR`.
2. Add a host rule `booking.local` to the Ingress and test it with `curl -H "Host: booking.local" http://<address>/mahaLogin/`.
3. Give the `viewer` ServiceAccount the built-in `view` ClusterRole with a **RoleBinding**, and list what changed with `kubectl auth can-i --list -n k8s-lab --as=…`.
4. Write an **Egress** policy so the booking pod can only reach DNS (UDP/TCP 53) and nothing else.
