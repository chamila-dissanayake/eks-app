# eks-app

Following is the order of applying modules
- [ ] vpc
- [ ] bastion
- [ ] shield
- [ ] rds
- [ ] lambda_layers
- [ ] lambda functions (har-engine, step-insights, pdf-generator, etc...)
- [ ] eks-ami
- [ ] eks-cluster
- [ ] namespace
- [ ] newrelic
- [ ] workloads (any deployments on top of eks-cluster)
- [ ] waf
- [ ] cloudfront - > front-ends (static content)
- [ ] health-check (Route53 health-checks)