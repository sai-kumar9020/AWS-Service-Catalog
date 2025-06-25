terraform {
  backend "s3" {
    bucket = "hcltrainings"
    key    = "service-catalog/terraform.tfstate"
    region = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
