# Helm Lab – turn our myjavaapp YAML into a Helm chart

**Goal:** deploy the online-booking Java app with **one Helm chart** instead of the separate
`mydeploy.yml` + `mySVCdeploy.yml` files, then upgrade it, roll it back and remove it.

**You need:** a running cluster (minikube, kind, or EKS) and `kubectl get nodes` already working.

```
helm/
├── HELM_LAB.md              <- this guide
└── myjavaapp/               <- the chart
    ├── Chart.yaml           chart name + version
    ├── values.yaml          default settings
    ├── values-dev.yaml      dev overrides   (1 pod, NodePort 30002)
    ├── values-prod.yaml     prod overrides  (3 pods, ECR image, LoadBalancer)
    └── templates/
        ├── _helpers.tpl     reusable name + labels
        ├── deployment.yaml  was mydeploy.yml
        ├── service.yaml     was mySVCdeploy.yml
        └── NOTES.txt        message printed after install
```

---

## Step 1 – Install Helm

| OS | Command |
|---|---|
| Windows (Chocolatey) | `choco install kubernetes-helm` |
| Linux / EC2 | `curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \| bash` |
| Mac | `brew install helm` |

Check it:

```bash
helm version
```

You should see `version.BuildInfo{Version:"v3.x.x" ...}` or `"v4.x.x"` – this chart works with both. Helm 3 and 4 need nothing installed inside the cluster – they use your kubeconfig, just like kubectl.

| OS | No admin rights? |
|---|---|
| Windows | `winget install --id Helm.Helm -e --scope user` (then open a new terminal) |

---

## Step 2 – Look at the chart

```bash
cd helm
cat myjavaapp/values.yaml
cat myjavaapp/templates/deployment.yaml
```

Compare `templates/deployment.yaml` with `../mydeploy.yml`. Same YAML, but the parts that change are now
`{{ .Values.... }}`:

| In mydeploy.yml | In the template | Comes from |
|---|---|---|
| `replicas: 2` | `replicas: {{ .Values.replicaCount }}` | values.yaml |
| `image: ...myjavaapp:2` | `image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"` | values.yaml |
| `name: myjavaapp-deploy` | `name: {{ include "myjavaapp.fullname" . }}` | release name + chart name |
| `namespace: production` | *(removed)* | `-n` at install time |

> Tip: to start a chart from zero you would run `helm create myjavaapp`, delete the sample files in
> `templates/`, and copy your own YAML in. That is how this chart was made.

---

## Step 3 – Check the chart before installing

```bash
helm lint ./myjavaapp
```

Expect: `1 chart(s) linted, 0 chart(s) failed`.

```bash
helm template booking-dev ./myjavaapp -f myjavaapp/values-dev.yaml
```

This prints the **final Kubernetes YAML** and installs nothing. Check that you see:
- `kind: Deployment` with `replicas: 1` and `image: "maha4iac/myonlinebooking:2"`
- `kind: Service` with `type: NodePort` and `nodePort: 30002`

Now see what prod would get – no install, just compare:

```bash
helm template booking-prod ./myjavaapp -f myjavaapp/values-prod.yaml
```

`replicas: 3`, the ECR image, `imagePullSecrets: ecr-secret` and `type: LoadBalancer`, with no nodePort.
**Same templates, different values.**

---

## Step 4 – Install the dev release

```bash
helm install booking-dev ./myjavaapp -f myjavaapp/values-dev.yaml -n dev --create-namespace
or 
helm install booking-dev ./myjavaapp -f myjavaapp/values-dev.yaml --set service.type=LoadBalancer -n dev --create-namespace


kubectl get pods -n dev -l release=booking-dev

```

Helm prints the text from `NOTES.txt`. Now check:

```bash
helm list -n dev
kubectl get all -n dev
```

You should see release `booking-dev` with REVISION `1`, 1 pod, and the Service `booking-dev-myjavaapp` on port `8080:30002`.

Open the app: `http://<node-ip>:30002/mahaLogin/` (find the node IP with `kubectl get nodes -o wide`;
on minikube use `minikube service booking-dev-myjavaapp -n dev --url`).

On **EKS with private nodes** (EXTERNAL-IP is `<none>`), use port-forward instead and keep that terminal open:

```bash
kubectl port-forward svc/booking-dev-myjavaapp 18080:8080 -n dev
```

Then open `http://localhost:18080/mahaLogin/` (the root `/` shows the Tomcat welcome page).

---

## Step 5 – Upgrade (revision 2)

Scale to 3 pods without touching any file:

```bash
helm upgrade booking-dev ./myjavaapp -f myjavaapp/values-dev.yaml --set replicaCount=3 -n dev
kubectl get pods -n dev
```

3 pods now. `--set` wins over the values files: **values.yaml → -f file → --set** (the last one wins).

> Keep passing `-f myjavaapp/values-dev.yaml` on every upgrade. Without it, Helm goes back to the defaults in `values.yaml`.

---

## Step 6 – History and rollback (revision 3)

```bash
helm history booking-dev -n dev
helm rollback booking-dev 1 -n dev
helm history booking-dev -n dev
kubectl get pods -n dev
```

You are back to 1 pod. The history shows **3** revisions: a rollback adds a new revision, it does not delete one.

---

## Step 7 – Uninstall

```bash
helm uninstall booking-dev -n dev
kubectl get all -n dev
```

The Deployment, pods and Service are all gone. One command removes the whole app.

---

## Step 8 (optional, EKS only) – Prod release from ECR

The prod values pull a **private** ECR image, so create the pull secret first (ECR passwords expire after 12 hours):

```bash
kubectl create namespace production
kubectl create secret docker-registry ecr-secret -n production \
  --docker-server=992558785875.dkr.ecr.us-east-2.amazonaws.com \
  --docker-username=AWS \
  --docker-password=$(aws ecr get-login-password --region us-east-2)

helm install booking-prod ./myjavaapp -f myjavaapp/values-prod.yaml -n production
kubectl get svc booking-prod-myjavaapp -n production     # wait for EXTERNAL-IP
```

---

## Troubleshooting

| Problem | Cause | Fix |
|---|---|---|
| `provided port is already allocated` | Another Service already uses NodePort 30002 (or 30001) | `kubectl get svc -A \| grep 3000`, then delete it or use `--set service.nodePort=30003` |
| `cannot re-use a name that is still in use` | The release already exists | `helm upgrade` instead, or `helm uninstall` first |
| Pods in `ImagePullBackOff` (prod) | `ecr-secret` missing or expired | Create it again (Step 8) |
| `Error: INSTALLATION FAILED: ... namespaces "dev" not found` | Forgot `--create-namespace` | Add it, or `kubectl create ns dev` |
| Service shows no endpoints | Selector labels do not match pod labels | Check with `helm template`. The chart uses the same helper for both, so this can't happen unless you edit only one side |

---

## Homework

1. Create `myjavaapp/values-test.yaml` with `replicaCount: 2` and `nodePort: 30003`.
2. Install it as `booking-test` in namespace `test` **while booking-dev is still running**.
3. Run `helm list -A` and explain why the two releases do not clash (compare with the 30001 problem in the plain YAML files).
