terraform {
  backend "s3" {
    bucket = "hcltrainings"
    key    = "service/terraform.tfstate"
    region = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
