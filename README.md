# Kubernetes Security Enhancement & Hardening

This repository contains an enterprise-grade, hardened Kubernetes deployment for the Django Healthchecks application. It demonstrates the implementation of **Pod Security Standards (Restricted)**, **Network Policies**, **Role-Based Access Control (RBAC)**, **SOPS + AWS KMS secret encryption**, and **Helm template testing**.

---

## 1. Repository Structure

```text
├── k8s_security_enhancement/             # Hardened application Helm chart
│   ├── charts/                           # Vendored immutable dependency charts
│   │   ├── cert-manager-v1.13.1.tgz
│   │   ├── ingress-nginx-4.8.1.tgz
│   │   └── metrics-server-3.11.0.tgz
│   ├── Chart.yaml                        # Chart metadata with declared dependencies
│   ├── .helmignore                       # Packaging ignore rules
│   ├── templates/                        # Hardened Kubernetes resource manifests
│   │   ├── _helpers.tpl                  # Standardized naming and label templates
│   │   ├── configmap.yaml                # Non-sensitive configuration
│   │   ├── deployment.yaml               # Hardened Deployment (Restricted PSS compliant)
│   │   ├── hpa.yaml                      # HorizontalPodAutoscaler (CPU & RAM)
│   │   ├── ingress.yaml                  # AWS NLB Ingress with TLS termination
│   │   ├── issuer.yaml                   # Cert-Manager ACME Let's Encrypt issuer
│   │   ├── networkpolicy.yaml            # Default-Deny ingress/egress NetworkPolicy
│   │   ├── NOTES.txt                     # Post-installation verification instructions
│   │   ├── ns.yaml                       # Namespace with Pod Security Admission labels
│   │   ├── secret.yaml                   # Secret resource manifest
│   │   ├── serviceaccount.yaml           # Dedicated SA & least-privilege RBAC Role/Binding
│   │   ├── service.yaml                  # ClusterIP internal service (:8080)
│   │   └── tests/
│   │       └── test-connection.yaml      # Automated Helm test hook
│   └── values.yaml                       # Baseline configuration & security contexts
├── helmfile.yaml                         # Declarative multi-chart environment orchestrator
└── helm_secrets/                         # GitOps encrypted secrets and environment config
    ├── django_config.yaml                # Non-secret environment overrides
    ├── django_secret.yaml                # SOPS + AWS KMS encrypted sensitive secrets
    └── .sops.yaml                        # SOPS encryption rules and KMS ARN definition
```

---

## 2. Why This Repository Structure Is the Best

This directory layout follows official CNCF and GitOps production best practices for several concrete architectural reasons:

### 2.1 Vendored Immutable Dependencies (`k8s_security_enhancement/charts/*.tgz`)
* **Supply-Chain Integrity & Air-Gapped Reliability:** In production environments, relying on external Helm repositories (`charts.jetstack.io`, `kubernetes.github.io/ingress-nginx`) at deploy-time introduces availability risks (upstream repository outages, rate limiting, domain expiration) and security risks (upstream chart tampering or retagging).
* Vendoring exact, pinned versions (`cert-manager-v1.13.1.tgz`, `ingress-nginx-4.8.1.tgz`, `metrics-server-3.11.0.tgz`) guarantees 100% reproducible, deterministic deployments across all environments without external network dependencies during chart installation.

### 2.2 Clear Separation of Concerns (Chart vs. Environment vs. Secrets)
* **Application Chart (`k8s_security_enhancement/`):** Contains purely generic, parameterized templates that define *how* the application runs, with no environment-specific hardcoding or credentials.
* **Environment Orchestrator (`helmfile.yaml`):** Sits at the root level to coordinate the lifecycle and installation order (`needs:`) of cluster add-ons (metrics-server, ingress-nginx, cert-manager) alongside the application chart.
* **Secrets Management (`helm_secrets/`):** Isolating encrypted secret files and the `.sops.yaml` configuration into their own dedicated directory prevents accidental template leaks, simplifies file-level access control in CI/CD pipelines, and cleanly delineates between public application code and sensitive credential configurations.

### 2.3 Strict Adherence to Helm Best Practices (`_helpers.tpl`, `NOTES.txt`, `tests/`)
* Placing template helpers in `_helpers.tpl` ensures DRY labels and consistent selector metadata (`app.kubernetes.io/name`, `app.kubernetes.io/instance`).
* Including `templates/tests/test-connection.yaml` allows continuous delivery pipelines to execute `helm test` automatically as a post-deployment gate before routing live production traffic.

---

## 3. Threat Assessment & Mitigation Strategies

Applying threat modeling based on the **STRIDE** and **MITRE ATT&CK for Kubernetes** matrices identified six critical attack vectors in default Kubernetes deployments:

| # | Threat Vector | Impact | Mitigation Implemented |
|---|---|---|---|
| **1** | **Container Escape & Node Takeover** | High / Critical | Run as non-root (`UID 1000`), `allowPrivilegeEscalation: false`, drop `ALL` Linux capabilities, enable `seccompProfile: RuntimeDefault`. |
| **2** | **Root Filesystem Modification & Malware Persistence** | High | `readOnlyRootFilesystem: true`. Transient writes redirected to constrained `emptyDir` on `/tmp`. |
| **3** | **Stolen ServiceAccount Token & API Enumeration** | Critical | `automountServiceAccountToken: false` on Pod and ServiceAccount. RBAC Role restricted strictly to necessary operations. |
| **4** | **Lateral Network Movement (Pod-to-Pod)** | High | Default-Deny `NetworkPolicy`. Ingress allowed only from `ingress-nginx`; Egress allowed only to CoreDNS (:53) and RDS PostgreSQL (:5432). |
| **5** | **Plaintext Credentials in Git** | Critical | Secrets encrypted with **Mozilla SOPS** using **AWS KMS** (`AES256_GCM`). In-memory decryption at deployment time via `helm-secrets`. |
| **6** | **Rogue Privileged Container Scheduling** | High | Namespace enforced with **Pod Security Admission (PSA)** at the `restricted` level (`pod-security.kubernetes.io/enforce: restricted`). |

---

## 4. Security Hardening Implementation Details

### 4.1 Pod Security Admission (PSA) & Namespace Hardening
Kubernetes v1.25+ enforces Pod Security Standards through built-in Pod Security Admission. We configured [`k8s_security_enhancement/templates/ns.yaml`](k8s_security_enhancement/templates/ns.yaml) with the strictest baseline:

```yaml
labels:
  pod-security.kubernetes.io/enforce: "restricted"
  pod-security.kubernetes.io/enforce-version: "latest"
  pod-security.kubernetes.io/audit: "restricted"
  pod-security.kubernetes.io/audit-version: "latest"
  pod-security.kubernetes.io/warn: "restricted"
  pod-security.kubernetes.io/warn-version: "latest"
```
* **Enforce:** Any pod that violates the Restricted standard is immediately rejected by the Kubernetes admission controller at deploy time.
* **Audit & Warn:** Violations trigger warning annotations in the API server audit logs.

### 4.2 Pod & Container SecurityContext Hardening
In [`k8s_security_enhancement/templates/deployment.yaml`](k8s_security_enhancement/templates/deployment.yaml), both pod-level and container-level contexts are configured:

```yaml
spec:
  # 1. Pod-level context
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
    fsGroupChangePolicy: "OnRootMismatch"
    seccompProfile:
      type: RuntimeDefault

  containers:
    - name: django-app
      # 2. Container-level context
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        capabilities:
          drop:
            - ALL
        seccompProfile:
          type: RuntimeDefault
```

* **`allowPrivilegeEscalation: false`:** Prevents binary child processes from gaining more privileges than their parent process (blocks `setuid` binaries).
* **`readOnlyRootFilesystem: true`:** Makes the entire root filesystem read-only. An attacker exploiting an application vulnerability cannot write web shells, overwrite libraries, or download malware. Writable requirements (e.g. Django `/tmp` caching) are mounted explicitly via an `emptyDir` volume with a memory limit (`sizeLimit: 128Mi`).
* **`capabilities: drop: ["ALL"]`:** Removes all 38+ default Linux kernel capabilities (including `CAP_NET_RAW`, `CAP_SYS_CHROOT`, `CAP_CHOWN`), stripping the process of administrative kernel access.
* **`seccompProfile: type: RuntimeDefault`:** Activates the default container runtime seccomp filter, blocking dangerous system calls (`ptrace`, `sys_chroot`, `reboot`).

### 4.3 Network Policy Isolation
In [`k8s_security_enhancement/templates/networkpolicy.yaml`](k8s_security_enhancement/templates/networkpolicy.yaml), a zero-trust network posture is enforced:

* **Ingress Restriction:**
  - Blocks all inbound traffic from other pods/namespaces.
  - Permits TCP traffic on port `8080` **only** from pods residing in the `ingress-nginx` namespace.
* **Egress Restriction:**
  - Blocks arbitrary outbound internet connections (preventing command-and-control communication and data exfiltration).
  - Explicitly whitelists:
    1. CoreDNS (`kube-system`, UDP/TCP :53) for cluster internal DNS resolution.
    2. Amazon RDS PostgreSQL (`10.20.0.0/16`, TCP :5432) for application database access.
    3. HTTPS (TCP :443) for necessary outbound API calls.

### 4.4 RBAC & ServiceAccount Hardening
In [`k8s_security_enhancement/templates/serviceaccount.yaml`](k8s_security_enhancement/templates/serviceaccount.yaml):
* **`automountServiceAccountToken: false`:** By default, Kubernetes mounts a JWT token at `/var/run/secrets/kubernetes.io/serviceaccount/token`. If an application is compromised via Remote Code Execution (RCE), attackers frequently use this token to query the Kubernetes API. Setting `automountServiceAccountToken: false` removes this attack vector entirely.
* **Least-Privilege Role & RoleBinding:** The pod is granted access only to the exact resources it needs (read-only `get`, `list` on its own ConfigMaps), adhering strictly to the principle of least privilege.

### 4.5 Secrets Encryption with SOPS + AWS KMS
* Encrypted file: [`helm_secrets/django_secret.yaml`](helm_secrets/django_secret.yaml)
* Master Key: AWS KMS (`arn:aws:kms:eu-north-1:669707688683:key/63cc3f9e-d07f-4fbf-9439-78e6d0421c30`)
* Algorithm: `AES256_GCM` authenticated symmetric encryption.
* Deployment: `helmfile sync` uses `helm-secrets` to decrypt the values in-memory only during template evaluation; plaintext values are never committed to version control.

### 4.6 Helm Template Testing
In [`k8s_security_enhancement/templates/tests/test-connection.yaml`](k8s_security_enhancement/templates/tests/test-connection.yaml):
* Defined as a Helm test hook (`"helm.sh/hook": test`).
* Runs as an ephemeral non-root container with restricted `securityContext`.
* Verifies HTTP reachability of the internal Service endpoint (`/api/v3/status/`) on port 8080.
* Can be triggered via:
  ```bash
  helm test django-secure-app -n django-security-prod
  ```

---

## 5. Verification Commands

```bash
# 1. Lint the hardened chart
helm lint ./k8s_security_enhancement

# 2. Render and inspect security contexts
helm template test ./k8s_security_enhancement

# 3. View decrypted secrets in stdout without writing plaintext to disk
helm secrets decrypt ./helm_secrets/django_secret.yaml

# 4. Deploy the complete environment via Helmfile
helmfile sync

# 5. Verify Pod Security Admission labels on namespace
kubectl get ns django-security-prod --show-labels

# 6. Verify running pods and active security contexts
kubectl get pods -n django-security-prod -o wide
kubectl get pods -n django-security-prod -o jsonpath='{.items[*].spec.securityContext}'

# 7. Run automated Helm template test
helm test django-secure-app -n django-security-prod
```
