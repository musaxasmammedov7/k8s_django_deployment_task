# Comprehensive Deployment Guide: Django on AWS EKS with RDS, Helm, and Helmfile

## Table of Contents

1. [Step 1: Kubernetes & Helm Primary Resources and Functionalities](#step-1-kubernetes--helm-primary-resources-and-functionalities)
2. [Step 2: Deploying the AWS Infrastructure (EKS Cluster, RDS PostgreSQL, ECR & KMS)](#step-2-deploying-the-aws-infrastructure-eks-cluster-rds-postgresql-ecr--kms)
3. [Step 3: Creating the Application Helm Chart & Encrypting Secrets](#step-3-creating-the-application-helm-chart--encrypting-secrets)
4. [Step 4: Orchestrating the Full Environment with Helmfile](#step-4-orchestrating-the-full-environment-with-helmfile)
5. [Step 5: Issues Faced & Solutions](#step-5-issues-faced--solutions)
6. [Step 6: Why Kubernetes and Helm Are Beneficial in This Scenario](#step-6-why-kubernetes-and-helm-are-beneficial-in-this-scenario)

---

## Step 1: Kubernetes & Helm Primary Resources and Functionalities

### 1.1 Kubernetes Core Resources Used

| Resource | API Version | Purpose in Our Architecture |
|---|---|---|
| **ConfigMap** | `v1` | Decouples non-sensitive configuration (`DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `ALLOWED_HOSTS`, `PORT="8080"`) from the container image so the same image runs across environments. |
| **Secret** | `v1` | Stores sensitive credentials (`SECRET_KEY`, `DB_PASSWORD`) injected into pods as environment variables at runtime. Encrypted in Git using `helm-secrets` + Mozilla SOPS + AWS KMS. |
| **Deployment** | `apps/v1` | Manages the stateless Django `ReplicaSet` (2 replicas on port `8080`), performs zero-downtime rolling updates, injects `ConfigMap` and `Secret` via `envFrom`, and runs `livenessProbe` and `readinessProbe` health checks. |
| **Service (`ClusterIP`)** | `v1` | Provides a stable internal virtual IP and DNS name (`django-app.django-app.svc.cluster.local:8080`) that load-balances traffic across all healthy Django pods. |
| **Ingress & Ingress Controller** | `networking.k8s.io/v1` | Provisions an internet-facing **AWS Network Load Balancer (NLB)** via `ingress-nginx` and routes external HTTP/HTTPS requests to the internal `ClusterIP` Service. |
| **Cert-Manager (`ClusterIssuer`)** | `cert-manager.io/v1` | Automates obtaining and renewing free TLS certificates from **Let's Encrypt** using the ACME HTTP-01 solver and stores the certificate in a Kubernetes TLS Secret (`django-app-tls`). |
| **HorizontalPodAutoscaler (`HPA`)** | `autoscaling/v2` | Queries `metrics-server` for real-time CPU and RAM usage and automatically scales the Django Deployment between **2 and 4 replicas** when CPU or Memory utilization hits **80%**. |

### 1.2 Helm & Helmfile Functionalities

* **Helm (`helm_chart/`)**: Packages all Kubernetes manifests for our Django application into reusable Go templates (`templates/*.yaml`) driven by `values.yaml`. It also tracks release revisions, supports atomic upgrades, and enables instant one-command rollbacks (`helm rollback`).
* **Helm Secrets (`helm-secrets` + SOPS + AWS KMS)**: Extends Helm to transparently decrypt SOPS-encrypted value files (`secrets.values.yaml`) in memory during `helm install` / `helm upgrade` / `helmfile apply` so plaintext secrets never touch disk or Git history.
* **Helmfile (`helmfile/helmfile.yaml`)**: Declaratively manages the entire cluster state—both third-party cluster add-ons (`metrics-server`, `ingress-nginx`, `cert-manager`) and our custom `django-app` chart—in a single file with dependency ordering (`needs:`).

---

## Step 2: Deploying the AWS Infrastructure (EKS Cluster, RDS PostgreSQL, ECR & KMS)

### 2.1 AWS Account & Region Setup
- **AWS Account ID**: `669707688683` (`arn:aws:iam::669707688683:root`)
- **AWS Region**: `eu-north-1` (Stockholm)

Verify credentials:
```bash
export DYLD_LIBRARY_PATH=/opt/homebrew/opt/expat/lib
aws sts get-caller-identity --profile default
```

### 2.2 Infrastructure Provisioned via Terraform (`terraform/main.tf`)
To make our setup reproducible and clean up easily when finished, we provisioned all AWS components using Terraform:

1. **VPC & Subnets (`10.20.0.0/16`)**:
   - 2 Public Subnets (`eu-north-1a`, `eu-north-1b`) tagged with `kubernetes.io/role/elb = 1` for AWS Load Balancer discovery.
   - 2 Private Subnets (`eu-north-1a`, `eu-north-1b`) tagged with `kubernetes.io/role/internal-elb = 1` for Amazon RDS PostgreSQL.
2. **AWS KMS Key (`alias/k8s-django-helm-secrets`)**:
   - ARN: `arn:aws:kms:eu-north-1:669707688683:key/096e059a-35bc-413c-bb4d-c5d02474c910`
   - Used by SOPS and `helm-secrets` to encrypt `helm_chart/secrets.values.yaml`.
3. **Amazon ECR Repository (`django-sample-app`)**:
   - URI: `669707688683.dkr.ecr.eu-north-1.amazonaws.com/django-sample-app`
4. **Amazon RDS PostgreSQL 16 (`django-k8s-postgres`)**:
   - Engine: PostgreSQL 16 (`db.t4g.micro`, 20 GB `gp3` encrypted storage)
   - Database Name: `hc`, Username: `hc`
   - Security Group (`django-k8s-cluster-rds-sg`): Allows inbound TCP port `5432` from the EKS VPC CIDR (`10.20.0.0/16`).
5. **Amazon EKS Cluster (`django-k8s-cluster`)**:
   - Kubernetes Version: `1.31`
   - Managed Node Group (`django-k8s-cluster-nodes`): 2 `t3.medium` EC2 worker nodes (auto-scalable from 2 to 4 nodes).

### 2.3 Building & Pushing the Django Image to Amazon ECR
Because Apple Silicon Macs (`darwin/arm64`) build ARM64 images by default while EKS `t3.medium` nodes use `x86_64`, we built and pushed the image targeting `--platform linux/amd64`:

```bash
aws ecr get-login-password --region eu-north-1 --profile default | \
  docker login --username AWS --password-stdin 669707688683.dkr.ecr.eu-north-1.amazonaws.com

docker buildx build --platform linux/amd64 \
  -t 669707688683.dkr.ecr.eu-north-1.amazonaws.com/django-sample-app:latest \
  --push /Users/musaxasmammedov/devops/django-sample-app-ecs-fargate
```

### 2.4 Configuring `kubectl` for Amazon EKS
```bash
aws eks update-kubeconfig --region eu-north-1 --name django-k8s-cluster --profile default
kubectl get nodes -o wide
```

---

## Step 3: Creating the Application Helm Chart & Encrypting Secrets

### 3.1 ConfigMap (`helm_chart/templates/configmap.yaml`)
Propagates non-sensitive configuration to the Django container:
- `DB: "postgres"`
- `DB_HOST`: RDS PostgreSQL endpoint (`django-k8s-postgres.<id>.eu-north-1.rds.amazonaws.com`)
- `DB_PORT: "5432"`
- `DB_NAME: "hc"`
- `DB_USER: "hc"`
- `DB_SSLMODE: "require"`
- `DEBUG: "False"`
- `ALLOWED_HOSTS: "*"`
- `PORT: "8080"`

### 3.2 Encrypting Secrets with `helm-secrets` + SOPS + AWS KMS (`helm_chart/templates/secrets.yaml`)
1. Installed SOPS and the `helm-secrets` plugin:
   ```bash
   brew install sops
   helm plugin install --verify=false https://github.com/jkroepke/helm-secrets
   helm plugin install --verify=false https://github.com/databus23/helm-diff
   ```
2. Configured `.sops.yaml` with our AWS KMS key ARN:
   ```yaml
   creation_rules:
     - path_regex: .*secrets.*\.yaml$
       kms: arn:aws:kms:eu-north-1:669707688683:key/096e059a-35bc-413c-bb4d-c5d02474c910
   ```
3. Encrypted `helm_chart/secrets.values.yaml` in-place:
   ```bash
   sops --encrypt --in-place helm_chart/secrets.values.yaml
   ```
   The resulting `helm_chart/secrets.values.yaml` stores `SECRET_KEY` and `DB_PASSWORD` as `ENC[AES256_GCM,...]` ciphertext protected by AWS KMS, making it completely safe to commit to GitHub.

### 3.3 Deployment (`helm_chart/templates/deployment.yaml`)
Satisfies all task requirements:
- **Replicas**: Runs **2 replicas** (`replicaCount: 2`).
- **Port 8080**: Overrides Gunicorn bind arguments to `--bind 0.0.0.0:8080` and exposes `containerPort: 8080`.
- **ConfigMap & Secret Propagation**: Uses `envFrom` with both `configMapRef` (`django-app-config`) and `secretRef` (`django-app-secret`).
- **Readiness & Liveness Probes**:
  - `readinessProbe`: `HTTP GET /api/v3/status/` on port `8080` (`initialDelaySeconds: 15`, `periodSeconds: 10`).
  - `livenessProbe`: `HTTP GET /api/v3/status/` on port `8080` (`initialDelaySeconds: 30`, `periodSeconds: 15`).
- **Resource Requests & Limits**: Requests `200m` CPU / `256Mi` RAM and limits at `500m` CPU / `512Mi` RAM so the HorizontalPodAutoscaler can compute utilization percentages.

### 3.4 ClusterIP Service (`helm_chart/templates/service.yaml`)
Exposes the Django pods internally on port `8080` (`type: ClusterIP`, `port: 8080`, `targetPort: 8080`).

### 3.5 AWS Ingress & Cert-Manager (`helm_chart/templates/ingress.yaml`)
- Defines a `cert-manager.io/v1` **`ClusterIssuer`** (`letsencrypt-prod`) configured with ACME server `https://acme-v02.api.letsencrypt.org/directory` and `http01` Ingress solver (`class: nginx`).
- Defines a `networking.k8s.io/v1` **`Ingress`** resource with:
  - `ingressClassName: nginx` (which provisions an internet-facing AWS Network Load Balancer).
  - Annotation `cert-manager.io/cluster-issuer: "letsencrypt-prod"`.
  - TLS block storing the certificate in `secretName: django-app-tls`.

### 3.6 HorizontalPodAutoscaler (`helm_chart/templates/hpa.yaml`)
Uses `autoscaling/v2` to scale `Deployment/django-app`:
- `minReplicas: 2`
- `maxReplicas: 4`
- Dual metrics:
  - `cpu` -> `averageUtilization: 80` (80%)
  - `memory` -> `averageUtilization: 80` (80%)

---

## Step 4: Orchestrating the Full Environment with Helmfile

Our `helmfile/helmfile.yaml` manages 4 releases in dependency order:
1. **`metrics-server`** (`kube-system`): Collects pod CPU and RAM metrics from kubelets for the HPA.
2. **`ingress-nginx`** (`ingress-nginx`): Deploys the NGINX Ingress Controller and provisions an internet-facing **AWS Network Load Balancer (NLB)** via AWS service annotations:
   - `service.beta.kubernetes.io/aws-load-balancer-type: "nlb"`
   - `service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"`
3. **`cert-manager`** (`cert-manager`): Installs Cert-Manager and its CustomResourceDefinitions (`crds.enabled: true`) for Let's Encrypt TLS automation.
4. **`django-app`** (`django-app`): Deploys our local chart `../helm_chart`, automatically decrypting `../helm_chart/secrets.values.yaml` via `helm-secrets`.

Deploy command:
```bash
cd helmfile
helmfile sync
```

### 4.1 Live Cluster Verification Outputs (`eu-north-1`)

#### EKS Worker Nodes (`c7i-flex.large`)
```text
$ kubectl get nodes -o wide
NAME                                         STATUS   ROLES    AGE   VERSION                INTERNAL-IP   EXTERNAL-IP      OS-IMAGE                        CONTAINER-RUNTIME
ip-10-20-1-56.eu-north-1.compute.internal    Ready    <none>   2m    v1.31.14-eks-b9510e3   10.20.1.56    16.171.242.67    Amazon Linux 2023.12.20261012   containerd://2.3.5+unknown
ip-10-20-2-145.eu-north-1.compute.internal   Ready    <none>   2m    v1.31.14-eks-b9510e3   10.20.2.145   16.170.252.243   Amazon Linux 2023.12.20261012   containerd://2.3.5+unknown
```

#### Deployed Pods, ClusterIP Service, AWS Load Balancer Ingress, HPA, ConfigMap & Secret
```text
$ kubectl get pods,svc,ingress,hpa,configmap,secret -n django-app -o wide
NAME                              READY   STATUS    RESTARTS   AGE   IP            NODE
pod/django-app-68b7db8869-88xrc   1/1     Running   0          97s   10.20.2.204   ip-10-20-2-145.eu-north-1.compute.internal
pod/django-app-68b7db8869-tkxph   1/1     Running   0          97s   10.20.1.243   ip-10-20-1-56.eu-north-1.compute.internal

NAME                 TYPE        CLUSTER-IP       EXTERNAL-IP   PORT(S)    AGE   SELECTOR
service/django-app   ClusterIP   172.20.159.242   <none>        8080/TCP   97s   app.kubernetes.io/instance=django-app,app.kubernetes.io/name=django-app

NAME                                   CLASS   HOSTS   ADDRESS                                                                          PORTS     AGE
ingress.networking.k8s.io/django-app   nginx   *       abb2b73e973174f3c92fca88ab77fb23-fdda5dcb00354aa1.elb.eu-north-1.amazonaws.com   80, 443   97s

NAME                                             REFERENCE               TARGETS                        MINPODS   MAXPODS   REPLICAS   AGE
horizontalpodautoscaler.autoscaling/django-app   Deployment/django-app   cpu: 5%/80%, memory: 77%/80%   2         4         2          97s

NAME                          DATA   AGE
configmap/django-app-config   13     97s

NAME                       TYPE     DATA   AGE
secret/django-app-secret   Opaque   2      97s
```

#### Cert-Manager `ClusterIssuer` & Certificate Status
```text
$ kubectl get clusterissuer,certificate -A
NAME                                             READY   AGE
clusterissuer.cert-manager.io/letsencrypt-prod   True    97s

NAMESPACE    NAME                                         READY   SECRET           AGE
django-app   certificate.cert-manager.io/django-app-tls   False   django-app-tls   97s
```

#### External HTTP Verification via AWS Network Load Balancer
```text
$ curl -i http://abb2b73e973174f3c92fca88ab77fb23-fdda5dcb00354aa1.elb.eu-north-1.amazonaws.com/api/v3/status/
HTTP/1.1 200 OK
Date: Mon, 19 Oct 2026 12:02:13 GMT
Content-Type: text/html; charset=utf-8
Content-Length: 2
Connection: keep-alive

OK

$ curl -I http://abb2b73e973174f3c92fca88ab77fb23-fdda5dcb00354aa1.elb.eu-north-1.amazonaws.com/accounts/login/
HTTP/1.1 200 OK
Date: Mon, 19 Oct 2026 12:02:14 GMT
Content-Type: text/html; charset=utf-8
Content-Length: 10071
```

---

## Step 5: Issues Faced & Solutions

During implementation, we encountered and resolved several real-world engineering issues:

### Issue 1: macOS Homebrew Python 3.14 `pyexpat` Dynamic Library Error with AWS CLI
- **Symptom**: Running `aws sts get-caller-identity` failed with:
  ```text
  aws: [ERROR]: dlopen(.../pyexpat.cpython-314-darwin.so): Symbol not found: _XML_SetAllocTrackerActivationThreshold
  Expected in: /usr/lib/libexpat.1.dylib
  ```
- **Root Cause**: Homebrew Python 3.14 was compiled against a newer `libexpat` version than macOS's system `/usr/lib/libexpat.1.dylib`.
- **Solution**: Exported `DYLD_LIBRARY_PATH=/opt/homebrew/opt/expat/lib` so the dynamic linker loads Homebrew's updated `libexpat.1.dylib`.

### Issue 2: Helm v4 Plugin Provenance Verification & `cli/v1` vs `getter/v1` Classification for `helm-secrets`
- **Symptom 1**: Running `helm plugin install https://github.com/jkroepke/helm-secrets` on Helm v4.2.0 failed because Helm v4 enforces cryptographic provenance signatures by default.
- **Symptom 2**: After installing with `--verify=false`, Helm v4 classified `helm-secrets` as `TYPE: getter/v1` instead of `cli/v1` because `plugin.yaml` included both `downloaders:` and `platformCommand:`, causing `helmfile` to fail with `Error: unknown command "secrets" for "helm"`.
- **Solution**: Installed the plugins with `--verify=false` and configured `/Users/musaxasmammedov/Library/helm/plugins/helm-secrets/plugin.yaml` with `command: "$HELM_PLUGIN_DIR/scripts/run.sh"` (omitting `downloaders:`), registering `secrets` as `cli/v1` (`helm secrets --version` -> `4.7.6`).

### Issue 3: Container Port 8000 vs Required Port 8080
- **Symptom**: The existing `Dockerfile` in `django-sample-app-ecs-fargate` bound Gunicorn to `0.0.0.0:8000` (`CMD ["gunicorn", ..., "--bind", "0.0.0.0:8000"]`), whereas our Kubernetes specification requires the application to operate on **port `8080`**.
- **Solution**: Parameterized `args` in `helm_chart/values.yaml` and `helm_chart/templates/deployment.yaml` to pass `--bind 0.0.0.0:8080` to Gunicorn and set `PORT: "8080"` in `ConfigMap`, ensuring Gunicorn listens on `8080` without duplicating the Dockerfile.

### Issue 4: YAML Document Separator Whitespace Chomp in `templates/ingress.yaml`
- **Symptom**: Running `helm lint helm_chart` initially reported:
  ```text
  [ERROR] templates/ingress.yaml: unable to parse YAML: invalid Yaml document separator: apiVersion: networking.k8s.io/v1
  ```
- **Root Cause**: In `templates/ingress.yaml`, placing `{{- if .Values.ingress.enabled -}}` with a trailing hyphen (`-}}`) stripped the newline immediately following `---`, concatenating `---apiVersion: networking.k8s.io/v1` onto a single line when `ClusterIssuer` was disabled or enabled.
- **Solution**: Changed `{{- if .Values.ingress.enabled -}}` to `{{- if .Values.ingress.enabled }}` to preserve the newline after `---`. Verified with `helm lint` (`0 chart(s) failed`).

### Issue 5: Apple Silicon (`arm64`) vs AWS EKS Node (`amd64`) Image Architecture Mismatch
- **Symptom**: Images built natively on an Apple Silicon Mac (`darwin/arm64`) fail on standard x86_64 EC2 nodes (`t3.medium`) with `exec format error`.
- **Solution**: Built and pushed the image using `docker buildx build --platform linux/amd64 ... --push`.

### Issue 6: Kubernetes Health Probes Failing Due to Django `ALLOWED_HOSTS`
- **Symptom**: Kubernetes `kubelet` sends `livenessProbe` and `readinessProbe` HTTP requests using the Pod's internal VPC IP address as the HTTP `Host` header. If Django's `ALLOWED_HOSTS` only lists the public domain, Django responds with `400 Bad Request (DisallowedHost)` and Kubernetes endlessly restarts the pods.
- **Solution**: Set `ALLOWED_HOSTS: "*"` in `ConfigMap` (`values.yaml`) and pointed both probes to `/api/v3/status/` on port `8080`.

### Issue 7: AWS Free Tier Plan Blocking `t3.medium` EKS Managed Node Group Instances
- **Symptom**: While provisioning the EKS Managed Node Group (`django-k8s-cluster-nodes`) with `t3.medium`, the EKS control plane and RDS PostgreSQL (`django-k8s-postgres.czmm644g0ujf.eu-north-1.rds.amazonaws.com`) finished creating, but the node group stayed in `CREATING` state for over 14 minutes with 0 nodes joining the cluster.
- **Root Cause**: Inspecting the underlying AWS Auto Scaling Group activities (`aws autoscaling describe-scaling-activities`) revealed:
  ```text
  Could not launch On-Demand Instances. InvalidParameterCombination - The specified instance type is not eligible for Free Tier. For a list of Free Tier instance types, run 'describe-instance-types' with the filter 'free-tier-eligible=true'. Launching EC2 instance failed.
  ```
  Because the AWS account (`669707688683`) is on the Free Tier plan, AWS blocks launching non-Free-Tier EC2 instance types such as `t3.medium`.
- **Solution**: Queried `aws ec2 describe-instance-types --filters "Name=free-tier-eligible,Values=true" --region eu-north-1` which returned `c7i-flex.large` (2 vCPUs, 4 GiB RAM), `m7i-flex.large` (2 vCPUs, 8 GiB RAM), `t3.small`, and `t3.micro`. Updated `terraform/main.tf` to use `instance_types = ["c7i-flex.large"]`, which immediately allowed the Auto Scaling Group to launch the EKS worker nodes.

---

## Step 6: Why Kubernetes and Helm Are Beneficial in This Scenario

1. **High Availability & Self-Healing (`Deployment` + Probes)**:
   - Unlike a single VM or static container setup, Kubernetes maintains 2 active replicas across multiple AWS Availability Zones. If Gunicorn hangs or crashes, `livenessProbe` restarts the container automatically; while database migrations run at startup, `readinessProbe` holds back user traffic until `/api/v3/status/` returns `200 OK`.
2. **Elastic Cost-Effective Scaling (`HorizontalPodAutoscaler`)**:
   - When CPU or RAM usage crosses 80%, the HPA automatically scales the Django tier from 2 to 4 replicas within seconds, and scales back down to 2 replicas during quiet periods.
3. **Managed Database Reliability with Stateless Compute (EKS + RDS)**:
   - Running stateless Django pods on EKS while delegating PostgreSQL storage to **Amazon RDS** gives the best of both worlds: rapid horizontal scaling for web workers without risking stateful database corruption, plus automated RDS backups and TLS encryption (`DB_SSLMODE=require`).
4. **Standardized, Repeatable Releases (`Helm` + `Helmfile` + `helm-secrets`)**:
   - Helm eliminates copy-pasted YAML manifests through templating, `helm-secrets` + AWS KMS secures sensitive credentials in Git, and `helmfile` turns a complex multi-component Kubernetes setup (`metrics-server`, `ingress-nginx`, `cert-manager`, and `django-app`) into a single deterministic command (`helmfile apply`).
