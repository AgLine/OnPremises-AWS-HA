############################################
# Deploy Application (Backend & Frontend)
############################################
resource "null_resource" "deploy_application" {
  depends_on = [
    null_resource.karpenter_nodepool,
    aws_db_instance.mariadb
  ]

  connection {
    type        = "ssh"
    host        = aws_instance.bastion.public_ip
    user        = "ec2-user"
    private_key = file("C:.ssh/bastion-key.pem")
  }

  provisioner "remote-exec" {
    inline = [
      # Backend Secret
      <<-EOT
      echo "Deploying Backend Secret..."
      
      cat <<EOF | kubectl apply -f -
      apiVersion: v1
      kind: Secret
      metadata:
        name: backend-db-secret
        namespace: default
      type: Opaque
      data:
        DB_USER: "${base64encode("admin")}"
        DB_PASSWORD: "${base64encode("")}"
        DB_HOST: "${base64encode(aws_db_instance.mariadb.endpoint)}"
        DB_NAME: "${base64encode("mydb")}"
        DB_PORT: "${base64encode("3306")}"
      EOF
      
      echo "Backend Secret deployed successfully"
      EOT
      ,
      # Backend Service
      <<-EOT
      echo "Deploying Backend Service..."
      
      cat <<EOF | kubectl apply -f -
      apiVersion: v1
      kind: Service
      metadata:
        name: backend-service
        namespace: default
        annotations:
          alb.ingress.kubernetes.io/healthcheck-path: /api/products
      spec:
        selector:
          app: my-backend
        ports:
          - protocol: TCP
            port: 80
            targetPort: 8080
        type: ClusterIP
      EOF
      
      echo "Backend Service deployed successfully"
      EOT
      ,
      # Frontend Service
      <<-EOT
      echo "Deploying Frontend Service..."
      
      cat <<EOF | kubectl apply -f -
      apiVersion: v1
      kind: Service
      metadata:
        name: frontend-service
        namespace: default
        annotations:
          alb.ingress.kubernetes.io/healthcheck-path: /
      spec:
        selector:
          app: my-frontend
        ports:
          - protocol: TCP
            port: 80
            targetPort: 80
        type: ClusterIP
      EOF

      echo "Frontend Service deployed successfully"
      EOT
      ,
      # Backend Deployment
      <<-EOT
      echo "Deploying Backend Deployment..."
      
      cat <<EOF | kubectl apply -f -
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: backend-deployment
        namespace: default
      spec:
        replicas: 2
        selector:
          matchLabels:
            app: my-backend
        template:
          metadata:
            labels:
              app: my-backend
          spec:
            containers:
            - name: my-backend-container
              image: 123456789.dkr.ecr.ap-northeast-2.amazonaws.com/my-backend:1.0
              env:
              - name: ALLOWED_ORIGIN
                value: "*"
              ports:
              - containerPort: 8080
              envFrom:
              - secretRef:
                  name: backend-db-secret
              resources:
                requests:
                  cpu: 100m
                  memory: 128Mi
                limits:
                  cpu: 500m
                  memory: 512Mi
      EOF
      
      echo "Backend Deployment deployed successfully"
      EOT
      ,
      # Frontend Deployment 배포
      <<-EOT
      echo "Deploying Frontend Deployment..."

      cat <<EOF | kubectl apply -f -
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: frontend-deployment
        namespace: default
      spec:
        replicas: 2
        selector:
          matchLabels:
            app: my-frontend
        template:
          metadata:
            labels:
              app: my-frontend
          spec:
            containers:
            - name: my-frontend-container
              image: 123456789.dkr.ecr.ap-northeast-2.amazonaws.com/my-frontend:19
              ports:
              - containerPort: 80
      EOF

      echo "Frontend Deployment deployed successfully"
      echo "Waiting for deployments to be ready..."
      kubectl wait --for=condition=available --timeout=300s deployment/backend-deployment
      kubectl wait --for=condition=available --timeout=300s deployment/frontend-deployment
      EOT
      ,
      # Application Ingress 배포 
      <<-EOT
      echo "Deploying Application Ingress..."
      
      cat <<EOF | kubectl apply -f -
      apiVersion: networking.k8s.io/v1
      kind: Ingress
      metadata:
        name: app-ingress
        namespace: default
        annotations:
          # --- 기존 어노테이션 유지 ---
          alb.ingress.kubernetes.io/scheme: internet-facing
          alb.ingress.kubernetes.io/target-type: ip
          alb.ingress.kubernetes.io/group.name: my-app
          alb.ingress.kubernetes.io/healthcheck-interval-seconds: '30'
          alb.ingress.kubernetes.io/healthy-threshold-count: '2'
          alb.ingress.kubernetes.io/unhealthy-threshold-count: '5'
          alb.ingress.kubernetes.io/actions.forward-weighted: >
            {
              "type": "forward",
              "forwardConfig": {
                "targetGroups": [
                  {
                    "serviceName": "frontend-service",
                    "servicePort": "80",
                    "weight": 60
                  },
                  {
                    "targetGroupARN": "arn:aws:elasticloadbalancing:ap-northeast-2:123456789:targetgroup/onprem/",
                    "weight": 40
                  }
                ]
              }
            }
      spec:
        ingressClassName: alb
        rules:
        - http:
            paths:
            - path: /api/products
              pathType: Prefix
              backend:
                service:
                  name: backend-service
                  port:
                    number: 80
            - path: /
              pathType: Prefix
              backend:
                service:
                  name: forward-weighted  
                  port:
                    name: use-annotation 
      EOF
      
      echo "Application Ingress deployed successfully"
      echo "Waiting for ALB to be provisioned..."
      sleep 60
      
      # ALB DNS 주소 출력
      echo "Getting ALB DNS name..."
      kubectl get ingress app-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' || echo "ALB is still being provisioned"
      EOT
      ,
      # 7. Backend HPA 배포
      <<-EOT
      echo "Waiting for Metrics Server to be ready..."
      kubectl wait --namespace=kube-system --for=condition=ready pod -l app.kubernetes.io/name=metrics-server --timeout=300s
      
      echo "Deploying Backend HPA..."
      
      cat <<EOF | kubectl apply -f -
      apiVersion: autoscaling/v2
      kind: HorizontalPodAutoscaler
      metadata:
        name: backend-hpa
        namespace: default
      spec:
        scaleTargetRef:
          apiVersion: apps/v1
          kind: Deployment
          name: backend-deployment
        minReplicas: 2
        maxReplicas: 5
        metrics:
        - type: Resource
          resource:
            name: cpu
            target:
              type: Utilization
              averageUtilization: 70
        - type: Resource
          resource:
            name: memory
            target:
              type: Utilization
              averageUtilization: 80
        behavior:
          scaleUp:
            stabilizationWindowSeconds: 60
            policies:
            - type: Percent
              value: 100
              periodSeconds: 15
          scaleDown:
            stabilizationWindowSeconds: 300
            policies:
            - type: Percent
              value: 50
              periodSeconds: 60
      EOF
      
      echo "Backend HPA deployed successfully"
      EOT
      ,
      # Frontend HPA 배포
      <<-EOT
      echo "Deploying Frontend HPA..."
      
      cat <<EOF | kubectl apply -f -
      apiVersion: autoscaling/v2
      kind: HorizontalPodAutoscaler
      metadata:
        name: frontend-hpa
        namespace: default
      spec:
        scaleTargetRef:
          apiVersion: apps/v1
          kind: Deployment
          name: frontend-deployment
        minReplicas: 2
        maxReplicas: 5
        metrics:
        - type: Resource
          resource:
            name: cpu
            target:
              type: Utilization
              averageUtilization: 70
        - type: Resource
          resource:
            name: memory
            target:
              type: Utilization
              averageUtilization: 80
        behavior:
          scaleUp:
            stabilizationWindowSeconds: 60
            policies:
            - type: Percent
              value: 100
              periodSeconds: 15
          scaleDown:
            stabilizationWindowSeconds: 300
            policies:
            - type: Percent
              value: 50
              periodSeconds: 60
      EOF

      echo "Frontend HPA deployed successfully"
      EOT
    ]
  }

  # RDS 엔드포인트가 변경되면 Secret도 다시 배포
  triggers = {
    db_endpoint = aws_db_instance.mariadb.endpoint
  }
}
