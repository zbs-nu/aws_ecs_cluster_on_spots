# -------------------------------------------------------------
#    ECS Cluster
# -------------------------------------------------------------
resource "aws_ecs_cluster" "cluster" {
  name               = var.cluster_name
  tags               = merge(var.standard_tags, tomap({ Name = var.cluster_name }))
  capacity_providers = [aws_ecs_capacity_provider.cluster_cp.name]

  setting {
    name  = "containerInsights"
    value = var.container_insights ? "enabled" : "disabled"
  }

  default_capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.cluster_cp.name
  }

  lifecycle {
    create_before_destroy = true
  }

  configuration {
    execute_command_configuration {
      logging    = "OVERRIDE"
      log_configuration {
        cloud_watch_encryption_enabled = true
        cloud_watch_log_group_name     = aws_cloudwatch_log_group.cluster_log_group.name
      }
    }
  }

  # https://github.com/terraform-providers/terraform-provider-aws/issues/11409
  # We need to terminate all instances before the cluster can be destroyed.
  # (Terraform would handle this automatically if the autoscaling group depended
  # on the cluster, but we need to have the dependency in the reverse
  # direction due to the capacity_providers field above).
  provisioner "local-exec" {
    when    = destroy

    command = <<CMD
      # Get the list of capacity providers associated with this cluster
      CAP_PROVS="$(aws ecs describe-clusters --clusters "${self.arn}" \
        --query 'clusters[*].capacityProviders[*]' --output text)"

      # Now get the list of autoscaling groups from those capacity providers
      ASG_ARNS="$(aws ecs describe-capacity-providers \
        --capacity-providers "$CAP_PROVS" \
        --query 'capacityProviders[*].autoScalingGroupProvider.autoScalingGroupArn' \
        --output text)"

      if [ -n "$ASG_ARNS" ] && [ "$ASG_ARNS" != "None" ]
      then
        for ASG_ARN in $ASG_ARNS
        do
          ASG_NAME=$(echo $ASG_ARN | cut -d/ -f2-)

          # Set the autoscaling group size to zero
          aws autoscaling update-auto-scaling-group \
            --auto-scaling-group-name "$ASG_NAME" \
            --min-size 0 --max-size 0 --desired-capacity 0

          # Remove scale-in protection from all instances in the asg
          INSTANCES="$(aws autoscaling describe-auto-scaling-groups \
            --auto-scaling-group-names "$ASG_NAME" \
            --query 'AutoScalingGroups[*].Instances[*].InstanceId' \
            --output text)"
          aws autoscaling set-instance-protection --instance-ids $INSTANCES \
            --auto-scaling-group-name "$ASG_NAME" \
            --no-protected-from-scale-in
        done
      fi
CMD
  }
}



# -------------------------------------------------------------
#    ASG: Auto Scaling Group
# -------------------------------------------------------------
resource "aws_autoscaling_group" "cluster_asg" {
  name                      = "${var.cluster_name}-ASG"
  max_size                  = var.cluster_max_size
  min_size                  = var.cluster_min_size
  desired_capacity          = var.cluster_desired_capacity
  protect_from_scale_in     = true
  vpc_zone_identifier       = var.ecs_subnet.*
  default_cooldown          = 300
  health_check_type         = "EC2"
  health_check_grace_period = 300
  termination_policies      = ["DEFAULT"]
  # service_linked_role_arn   = aws_iam_role.ecs_service_role.arn

  tag {
    key                 = "AmazonECSManaged"
    value               = "Yes"
    propagate_at_launch = true
  }
  tag {
    key                 = "Name"
    value               = var.cluster_name
    propagate_at_launch = true
  }

  mixed_instances_policy {
    instances_distribution {
      on_demand_base_capacity  = 0
      spot_allocation_strategy = "lowest-price"
      spot_instance_pools      = 5
    }
    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.cluster_lt.id
        version            = "$Latest"
      }
      dynamic "override" {
        for_each = var.instance_types
        content {
          instance_type       = override.key
          weighted_capacity   = override.value
        }
      }
    }
  }
}



# -------------------------------------------------------------
#    Launch Template
# -------------------------------------------------------------
resource "aws_launch_template" "cluster_lt" {
  name                      = "${var.cluster_name}-LT"
  image_id                  = data.aws_ami.amazon_linux_ecs.id
  instance_type             = "t3a.small"
  iam_instance_profile {
    name                    = aws_iam_instance_profile.ecs_node.name ## aws_iam_role.ecs_service_role.arn ## "arn:aws:iam::${var.account}:instance-profile/ecsInstanceRole"
  }
  key_name                  = var.key_name
  user_data                 = base64encode(templatefile("${path.module}/user-data.sh", { cluster_name = var.cluster_name }))

  dynamic "block_device_mappings" {
    for_each = var.ebs_disks
    content {
      device_name = block_device_mappings.key
      ebs {
        volume_size           = block_device_mappings.value
        volume_type           = var.ebs_volume_type
        encrypted             = var.ebs_encrypted
        delete_on_termination = var.ebs_delete_on_termination
      }
    }
  }  

  network_interfaces {
    subnet_id       = var.ecs_subnet[0]
    security_groups = var.cluster_sg
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(var.standard_tags, tomap({ Name = var.cluster_name }))
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(var.standard_tags, tomap({ Name = var.cluster_name }))
  }
}



# -------------------------------------------------------------
#    Capacity Providers
# -------------------------------------------------------------
resource "aws_ecs_capacity_provider" "cluster_cp" {
  name = var.cluster_name
  
  auto_scaling_group_provider {
    auto_scaling_group_arn         = aws_autoscaling_group.cluster_asg.arn
    managed_termination_protection = "ENABLED"

    managed_scaling {
      maximum_scaling_step_size    = 1000
      minimum_scaling_step_size    = 1
      status                       = "ENABLED"
      target_capacity              = 100
    }
  }
}
