provider "aws" {
  region = var.region
}

# Create a unique S3 bucket for templates
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "template_bucket" {
  bucket = "service-catalog-templates-${random_id.bucket_suffix.hex}"
  # IMPORTANT: Add a public access block to ensure it's not publicly accessible
  # Service Catalog will access it internally.
  
}

resource "aws_s3_bucket_public_access_block" "template_bucket_public_access_block" {
  bucket = aws_s3_bucket.template_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}


## 1. Create Service Catalog Portfolio
resource "aws_servicecatalog_portfolio" "web_app_portfolio" {
  name          = "WebApplicationPortfolio"
  description   = "Portfolio for web application products"
  provider_name = "IT Department"
}

## 2. Create IAM Role for Launch Constraints with proper permissions
resource "aws_iam_role" "launch_constraint_role" {
  name = "SCWebAppLaunchRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sts:AssumeRole",
        Effect = "Allow",
        Principal = {
          Service = "servicecatalog.amazonaws.com"
        },
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          },
          ArnLike = {
            "aws:SourceArn" = "arn:aws:servicecatalog:${var.region}:${data.aws_caller_identity.current.account_id}:*"
          }
        }
      }
    ]
  })
}

data "aws_caller_identity" "current" {}

# ATTENTION: Using AdministratorAccess for a launch role is highly permissive.
# For production, create a custom policy with only the necessary permissions
# for the resources defined in your CloudFormation template (EC2, ELB, S3, etc.).
resource "aws_iam_role_policy_attachment" "launch_constraint_policy" {
  role       = aws_iam_role.launch_constraint_role.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# This custom policy seems redundant if AdministratorAccess is already attached,
# but it also grants S3 read access to the bucket.
# Ensure your CloudFormation template's services are covered by permissions.
resource "aws_iam_role_policy" "service_catalog_policy" {
  name = "ServiceCatalogAdditionalPermissions"
  role = aws_iam_role.launch_constraint_role.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion"
        ],
        Effect   = "Allow",
        Resource = "${aws_s3_bucket.template_bucket.arn}/*"
      },
      {
        Action = [
          "cloudformation:*",
          "servicecatalog:*" # This is for Service Catalog *itself* to perform actions related to products/portfolios, not for provisioning.
                             # The actual provisioning permissions come from the attached AdministratorAccess.
        ],
        Effect   = "Allow",
        Resource = "*"
      }
    ]
  })
}

## 3. Create CloudFormation Template for Web App
# Ensure ec2_instance_cft.yaml exists in the same directory as your main.tf
data "template_file" "web_app_template" {
  template = file("${path.module}/ec2_instance_cft.yaml")
}

resource "aws_s3_object" "web_app_template_object" { # Renamed to avoid conflict with data source name
  bucket  = aws_s3_bucket.template_bucket.bucket
  key     = "templates/ec2_instance_cft.yaml"
  content = data.template_file.web_app_template.rendered
  etag    = filemd5("${path.module}/ec2_instance_cft.yaml") # Ensure update on file change
  content_type = "text/plain" # Important for YAML files
}


## 4. Create Service Catalog Product
resource "aws_servicecatalog_product" "web_app_product" {
  name              = "WebApplicationProduct"
  owner             = "IT Department"
  type              = "CLOUD_FORMATION_TEMPLATE"
  description       = "Web Application with EC2 and ALB"

  provisioning_artifact_parameters {
    description      = "Initial version"
    name             = "v1.0"
    template_url     = "https://${aws_s3_bucket.template_bucket.bucket_regional_domain_name}/${aws_s3_object.web_app_template_object.key}"
    type             = "CLOUD_FORMATION_TEMPLATE"
  }

  tags = {
    "Category" = "WebApplications"
  }
}

## 5. Associate Product with Portfolio
resource "aws_servicecatalog_product_portfolio_association" "web_app_association" {
  portfolio_id = aws_servicecatalog_portfolio.web_app_portfolio.id
  product_id   = aws_servicecatalog_product.web_app_product.id
}

## 6. Add Launch Constraint
resource "aws_servicecatalog_constraint" "web_app_launch_constraint" {
  description  = "Launch constraint for web application"
  portfolio_id = aws_servicecatalog_portfolio.web_app_portfolio.id
  product_id   = aws_servicecatalog_product.web_app_product.id
  type         = "LAUNCH"

  parameters = jsonencode({
    "RoleArn" : aws_iam_role.launch_constraint_role.arn
  })

  # Dependencies should be automatically inferred by Terraform for the RoleArn reference
  # but explicitly adding them here doesn't hurt.
  depends_on = [
    aws_iam_role_policy.service_catalog_policy,
    aws_iam_role_policy_attachment.launch_constraint_policy,
    aws_iam_role.launch_constraint_role # Ensure the role itself is created
  ]
}

## 7. Grant Access to Users/Groups
resource "aws_servicecatalog_principal_portfolio_association" "developer_access" {
  portfolio_id  = aws_servicecatalog_portfolio.web_app_portfolio.id
  principal_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/saikumar" # Ensure this IAM user exists
  principal_type = "IAM" # Explicitly define principal_type
}

# Outputs for verification
output "portfolio_id" {
  description = "The ID of the Service Catalog Portfolio"
  value       = aws_servicecatalog_portfolio.web_app_portfolio.id
}

output "product_id" {
  description = "The ID of the Service Catalog Product"
  value       = aws_servicecatalog_product.web_app_product.id
}

output "launch_role_arn" {
  description = "The ARN of the Service Catalog Launch Role"
  value       = aws_iam_role.launch_constraint_role.arn
}


