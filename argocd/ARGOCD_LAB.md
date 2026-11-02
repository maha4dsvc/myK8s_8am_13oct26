# Argo CD Lab – deploy our Helm chart from GitHub with GitOps

**Goal:** stop running `helm install` from a laptop. Argo CD runs inside the cluster, watches this GitHub repo,
and deploys `helm/myjavaapp` automatically. To change the app, you change Git.

**You need:**
- A running cluster with `kubectl get nodes` working (minikube, kind or EKS)
- The Helm lab done once (you know the `myjavaapp` chart)
- For step 5: push access to the repo (your own fork, or the teacher does it live)

```
argocd/
├── ARGOCD_LAB.md             <- this guide
├── ArgoCD_for_Kubernetes.pptx
├── application-dev.yaml      <- auto-sync, namespace dev
└── application-prod.yaml     <- manual sync, namespace production
helm/myjavaapp/               <- the chart Argo CD deploys (unchanged)
```

---

## Step 1 – Install Argo CD

```bash
kubectl create namespace argocd
kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl get pods -n argocd -w
```

Wait until all pods are `Running` (1–3 minutes), then press Ctrl+C:

| Pod | Job |
|---|---|
| `argocd-server` | Web UI, API and CLI endpoint |
| `argocd-repo-server` | Clones Git and runs `helm template` on our chart |
| `argocd-application-controller-0` | Compares Git with the cluster and syncs |
| `argocd-redis` | Cache |
| `argocd-dex-server` | SSO login (not used in this lab) |
| `argocd-applicationset-controller` | Creates many Applications from one template |
| `argocd-notifications-controller` | Slack / email alerts |

> `--server-side` avoids the error *"metadata.annotations: Too long"* on the big Argo CD CRDs.

---

## Step 2 – Open the UI and log in

**Terminal 1** – keep it open:

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

**Terminal 2** – get the admin password:

| Shell | Command |
|---|---|
| bash / Git Bash / Linux | `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" \| base64 -d` |
| PowerShell | `[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String((kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}")))` |
| argocd CLI | `argocd admin initial-password -n argocd` |

Open **https://localhost:8080**, accept the certificate warning (Advanced → Proceed), log in as `admin`.

**Optional – install the argocd CLI:**

| OS | Command |
|---|---|
| Windows (admin PowerShell) | `choco install argocd-cli` |
| Linux / EC2 | `curl -sSL -o argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64 && sudo install -m 555 argocd /usr/local/bin/argocd` |
| Mac | `brew install argocd` |

```bash
argocd login localhost:8080 --username admin --insecure
argocd account update-password
```

---

## Step 3 – Hand the app over from Helm to Argo CD

If you still have the Helm release from the Helm lab, remove it first. **Never manage the same app with
`helm upgrade` and Argo CD at the same time** – they will overwrite each other.

```bash
helm list -A
helm uninstall booking-dev -n dev        # only if it is listed
```

---

## Step 4 – Create the Application

```bash
kubectl apply -f argocd/application-dev.yaml
```

In the UI the `booking-dev` tile appears, goes **OutOfSync → Syncing → Synced**, and health turns **Healthy**.
Click the tile to see the tree: Application → Service + Deployment → ReplicaSet → Pods.

Check from the terminal:

```bash
kubectl get applications -n argocd
kubectl get all -n dev
helm list -n dev                         # EMPTY – Argo CD uses helm template, not helm install
```

| Expected | Value |
|---|---|
| Sync status | `Synced` |
| Health | `Healthy` |
| Pods | as many as `replicaCount` in `values-dev.yaml` |
| Service | `booking-dev-myjavaapp`, NodePort `30002` |

Open the app (EKS with private nodes):

```bash
kubectl port-forward svc/booking-dev-myjavaapp 18080:8080 -n dev
```


→ **http://localhost:18080/mahaLogin/**

---

## Step 5 – Deploy by git push (the GitOps part)

Edit `helm/myjavaapp/values-dev.yaml` and change `replicaCount` (for example `2` → `3`), then:

```bash
git add helm/myjavaapp/values-dev.yaml
git commit -m "dev: scale to 3 pods"
git push
```

Argo CD checks Git every **3 minutes**. To skip the wait, click **REFRESH** in the UI or run
`argocd app get booking-dev --refresh`. Then:

```bash
kubectl get pods -n dev                  # now 3 pods
argocd app history booking-dev           # each sync with its Git commit id
```

**Rollback = git revert:**

```bash
git revert HEAD
git push
```

Argo CD deploys the previous version again. The Git log is now your deployment history.

---

## Step 6 – Drift and self-heal

Change the cluster by hand, the way people often do by mistake:

```bash
kubectl scale deploy booking-dev-myjavaapp -n dev --replicas=5
kubectl get pods -n dev -w
```

Within seconds the extra pods are removed again: the app went **OutOfSync**, and `selfHeal: true` put it back to
what Git says. Watch it happen in the UI.

> Try the same with `selfHeal` removed from the Application: the app stays OutOfSync until someone presses SYNC.

---

## Step 7 – See the difference before syncing (optional)

```bash
argocd app diff booking-dev
argocd app manifests booking-dev | head -40     # the YAML Argo CD rendered from our chart
```

---

## Step 8 (optional) – Prod with manual sync

Prod pulls the private ECR image, so the pull secret must exist first (ECR passwords expire after 12 hours):

```bash
kubectl create namespace production
kubectl create secret docker-registry ecr-secret -n production \
  --docker-server=992558785875.dkr.ecr.us-east-2.amazonaws.com \
  --docker-username=AWS \
  --docker-password=$(aws ecr get-login-password --region us-east-2)
```

If `booking-prod` is still a Helm release, `helm uninstall booking-prod -n production` first. Then:

```bash
kubectl apply -f argocd/application-prod.yaml
```

The app shows **OutOfSync** and does nothing – that is manual sync. Press **SYNC** in the UI, or:

```bash
argocd app sync booking-prod
kubectl get svc booking-prod-myjavaapp -n production      # EXTERNAL-IP = LoadBalancer URL
```

Open `http://<EXTERNAL-IP>:8080/login/`.

---

## Step 9 – Clean up

```bash
kubectl delete -f argocd/application-dev.yaml       # finalizer also deletes the pods and Service
kubectl delete -f argocd/application-prod.yaml      # if you did step 8 (removes the AWS LoadBalancer)
kubectl delete namespace dev production
kubectl delete -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl delete namespace argocd
```

---

## Troubleshooting

| Problem | Cause | Fix |
|---|---|---|
| `Unknown` sync status, *"repository not found"* | Repo is private or URL wrong | Make the repo public, or `argocd repo add <url> --username … --password <token>` |
| `ComparisonError … values-dev.yaml not found` | `valueFiles` path wrong | It is relative to `path:` (the chart folder) |
| Synced but **Degraded**, pods `ImagePullBackOff` | Image tag missing, or `ecr-secret` missing/expired | Check `image.tag` in the values file; recreate the secret |
| Change pushed but nothing happens | Polling waits up to 3 min | Click REFRESH, or `argocd app get <app> --refresh` |
| `provided port is already allocated` | A Helm-made Service still uses NodePort 30002 | `helm uninstall booking-dev -n dev` (step 3) |
| App stuck deleting | Finalizer waiting for resources | `kubectl get all -n dev`; delete leftovers, or remove the finalizer |
| Port-forward stops | Terminal closed or pod restarted | Run the `kubectl port-forward` command again |

---

## Homework

1. Create `helm/myjavaapp/values-test.yaml` (`replicaCount: 1`, `nodePort: 30003`).
2. Create `argocd/application-test.yaml` for namespace `test` with auto-sync.
3. Push both, apply the Application, and show **three** apps (dev, test, prod) in the Argo CD UI.
