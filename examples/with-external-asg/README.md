# Example: compose with an external ASG module

Adopt the pointer model without letting this module own your fleet. Here
`create_asg = false`, so the module manages only the SSM release pointer, and
[`terraform-aws-modules/autoscaling`](https://registry.terraform.io/modules/terraform-aws-modules/autoscaling/aws)
owns the ASG and launch template. The only coupling is one line:

```hcl
image_id = "resolve:ssm:${module.pointer.ssm_parameter_name}"
```

After `apply`, deploy exactly as with a managed ASG — the driver only needs the
ASG name and the pointer name:

```sh
scripts/deploy.sh \
  --asg   "$(terraform output -raw asg_name)" \
  --param "$(terraform output -raw ssm_parameter_name)" \
  deploy ami-0123456789abcdef0
```

See [`docs/DESIGN.md`](../../docs/DESIGN.md) (D7) for why the module composes
instead of wrapping the upstream ASG module.
