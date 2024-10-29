#!/bin/bash

set -e

cd $(dirname $0)

#docker build -t registry.k8s.io/kueue/kueue:$TAG .
CGO_ENABLED=0 go build -gcflags='all=-l -N' -o cmd/kueue/kueue cmd/kueue/main.go

TAG=$(date +%d%H%M)
docker build -t registry.k8s.io/kueue/kueue:$TAG -f Dockerfile.dev .

kind load docker-image registry.k8s.io/kueue/kueue:$TAG --name kueue-test

kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    app.kubernetes.io/component: controller
    app.kubernetes.io/name: kueue
    control-plane: controller-manager
  name: kueue-controller-manager
  namespace: kueue-system
spec:
  replicas: 1
  selector:
    matchLabels:
      control-plane: controller-manager
  template:
    metadata:
      annotations:
        kubectl.kubernetes.io/default-container: manager
      labels:
        control-plane: controller-manager
    spec:
      containers:
      - args:
        - --config=/controller_manager_config.yaml
        - --zap-log-level=5
        command:
        - /kueue
        image: registry.k8s.io/kueue/kueue:$TAG
        imagePullPolicy: Never
        # livenessProbe:
        #   httpGet:
        #     path: /healthz
        #     port: 8081
        #   initialDelaySeconds: 15
        #   periodSeconds: 20
        name: manager
        ports:
        - containerPort: 8082
          name: visibility
          protocol: TCP
        - containerPort: 9443
          name: webhook-server
          protocol: TCP
        # readinessProbe:
        #   httpGet:
        #     path: /readyz
        #     port: 8081
        #   initialDelaySeconds: 5
        #   periodSeconds: 10
        resources:
          limits:
            cpu: 500m
            memory: 512Mi
          requests:
            cpu: 500m
            memory: 512Mi
        securityContext:
          allowPrivilegeEscalation: false
        volumeMounts:
        - mountPath: /tmp/k8s-webhook-server/serving-certs
          name: cert
          readOnly: true
        - mountPath: /controller_manager_config.yaml
          name: manager-config
          subPath: controller_manager_config.yaml
      - args:
        - --secure-listen-address=0.0.0.0:8443
        - --upstream=http://127.0.0.1:8080/
        - --logtostderr=true
        - --v=10
        image: gcr.io/kubebuilder/kube-rbac-proxy:v0.8.0
        name: kube-rbac-proxy
        ports:
        - containerPort: 8443
          name: https
          protocol: TCP
      securityContext:
        runAsNonRoot: true
      serviceAccountName: kueue-controller-manager
      terminationGracePeriodSeconds: 10
      volumes:
      - name: cert
        secret:
          defaultMode: 420
          secretName: kueue-webhook-server-cert
      - configMap:
          name: kueue-manager-config
        name: manager-config
---
apiVersion: v1
data:
  controller_manager_config.yaml: |
    apiVersion: config.kueue.x-k8s.io/v1beta1
    kind: Configuration
    health:
      healthProbeBindAddress: :8081
    metrics:
      bindAddress: :8080
    # enableClusterQueueResources: true
    webhook:
      port: 9443
    leaderElection:
      leaderElect: false
      #resourceName: c1f6bfd2.kueue.x-k8s.io
    controller:
      groupKindConcurrency:
        Job.batch: 5
        Pod: 5
        Workload.kueue.x-k8s.io: 5
        LocalQueue.kueue.x-k8s.io: 1
        ClusterQueue.kueue.x-k8s.io: 1
        ResourceFlavor.kueue.x-k8s.io: 1
    clientConnection:
      qps: 50
      burst: 100
    #pprofBindAddress: :8083
    #waitForPodsReady:
    #  enable: false
    #  timeout: 5m
    #  blockAdmission: false
    #  requeuingStrategy:
    #    timestamp: Eviction
    #    backoffLimitCount: null # null indicates infinite requeuing
    #    backoffBaseSeconds: 60
    #    backoffMaxSeconds: 3600
    #manageJobsWithoutQueueName: true
    #internalCertManagement:
    #  enable: false
    #  webhookServiceName: ""
    #  webhookSecretName: ""
    integrations:
      frameworks:
      - "batch/job"
      - "kubeflow.org/mpijob"
      - "ray.io/rayjob"
      - "ray.io/raycluster"
      - "jobset.x-k8s.io/jobset"
      - "kubeflow.org/mxjob"
      - "kubeflow.org/paddlejob"
      - "kubeflow.org/pytorchjob"
      - "kubeflow.org/tfjob"
      - "kubeflow.org/xgboostjob"
    #  - "pod"
    #  externalFrameworks:
    #  - "Foo.v1.example.com"
    #  podOptions:
    #    namespaceSelector:
    #      matchExpressions:
    #        - key: kubernetes.io/metadata.name
    #          operator: NotIn
    #          values: [ kube-system, kueue-system ]
    #fairSharing:
    #  enable: true
    #  preemptionStrategies: [LessThanOrEqualToFinalShare, LessThanInitialShare]
    #resources:
    #  excludeResourcePrefixes: []
kind: ConfigMap
metadata:
  labels:
    app.kubernetes.io/component: controller
    app.kubernetes.io/name: kueue
    control-plane: controller-manager
  name: kueue-manager-config
  namespace: kueue-system
EOF


