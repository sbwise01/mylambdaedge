provider "aws" {
  region = "us-east-2"
}

provider "aws" {
  alias  = "us-east-1"
  region = "us-east-1"
}

terraform {
  required_version = "~> 0.12.31"

  backend "s3" {
    bucket  = "bw-terraform-state-us-east-1"
    key     = "edgelambda.tfstate"
    region  = "us-east-1"
    profile = "foghorn-io-brad"
  }
}

locals {
  parent_domain_name = "aws.bradandmarsha.com"
  app_zone_name      = "app.${local.parent_domain_name}"
  buckets_prefix     = "brad"
}

resource "aws_route53_zone" "parent_zone" {
  name              = local.parent_domain_name
  delegation_set_id = "N03386422VXZJKGR4YO18"
}

resource "aws_route53_zone" "app_zone" {
  name = local.app_zone_name
}

resource "aws_route53_record" "app_zone_delegation" {
  allow_overwrite = true
  name            = local.app_zone_name
  ttl             = 300
  type            = "NS"
  zone_id         = aws_route53_zone.parent_zone.id
  records         = aws_route53_zone.app_zone.name_servers
}

resource "aws_route53_record" "live" {
  zone_id = aws_route53_zone.app_zone.zone_id
  name    = "www"
  type    = "A"
  alias {
    name                   = aws_cloudfront_distribution.cf-web.domain_name
    zone_id                = aws_cloudfront_distribution.cf-web.hosted_zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "test" {
  zone_id = aws_route53_zone.app_zone.zone_id
  name    = "www-test"
  type    = "A"
  alias {
    name                   = aws_cloudfront_distribution.cf-web.domain_name
    zone_id                = aws_cloudfront_distribution.cf-web.hosted_zone_id
    evaluate_target_health = true
  }
}

resource "aws_acm_certificate" "cert" {
  provider                  = aws.us-east-1
  domain_name               = local.app_zone_name
  subject_alternative_names = ["*.${local.app_zone_name}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.cert.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  name            = each.value.name
  type            = each.value.type
  zone_id         = aws_route53_zone.app_zone.zone_id
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "cert" {
  provider                = aws.us-east-1
  certificate_arn         = aws_acm_certificate.cert.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

resource "aws_s3_bucket" "web-bucket" {
  bucket        = "${local.buckets_prefix}-web-bucket"
  acl           = "public-read"
  force_destroy = true
  website {
    error_document = "error.html"
    index_document = "index.html"
  }
}

resource "aws_s3_bucket_object" "default-index-page" {
  bucket        = aws_s3_bucket.web-bucket.id
  acl           = "public-read"
  force_destroy = true
  key           = "index.html"
  content       = templatefile("files/web/index.html", { buckets_prefix = local.buckets_prefix })
  content_type  = "text/html"
}

resource "aws_s3_bucket_object" "blue-index-page" {
  bucket        = aws_s3_bucket.web-bucket.id
  acl           = "public-read"
  force_destroy = true
  key           = "blue/index.html"
  content       = templatefile("files/web/blue/index.html", { buckets_prefix = local.buckets_prefix })
  content_type  = "text/html"
}

resource "aws_s3_bucket_object" "green-index-page" {
  bucket        = aws_s3_bucket.web-bucket.id
  acl           = "public-read"
  force_destroy = true
  key           = "green/index.html"
  content       = templatefile("files/web/green/index.html", { buckets_prefix = local.buckets_prefix })
  content_type  = "text/html"
}

resource "aws_s3_bucket" "static-content-bucket" {
  bucket        = "${local.buckets_prefix}-static-content-bucket"
  acl           = "public-read"
  force_destroy = true
  website {
    error_document = "error.html"
    index_document = "index.html"
  }
}

resource "aws_s3_bucket_object" "default-image" {
  bucket        = aws_s3_bucket.static-content-bucket.id
  acl           = "public-read"
  force_destroy = true
  key           = "image.jpg"
  source        = "files/static_content/image.jpg"
  content_type  = "image/jpeg"

  etag = filemd5("files/static_content/image.jpg")
}

resource "aws_s3_bucket_object" "blue-image" {
  bucket        = aws_s3_bucket.static-content-bucket.id
  acl           = "public-read"
  force_destroy = true
  key           = "blue/image.jpg"
  source        = "files/static_content/blue/image.jpg"
  content_type  = "image/jpeg"

  etag = filemd5("files/static_content/blue/image.jpg")
}

resource "aws_s3_bucket_object" "green-image" {
  bucket        = aws_s3_bucket.static-content-bucket.id
  acl           = "public-read"
  force_destroy = true
  key           = "green/image.jpg"
  source        = "files/static_content/green/image.jpg"
  content_type  = "image/jpeg"

  etag = filemd5("files/static_content/green/image.jpg")
}

resource "aws_cloudfront_origin_access_identity" "cf-web" {
}

resource "aws_cloudfront_distribution" "cf-web" {
  origin {
    domain_name = aws_s3_bucket.web-bucket.bucket_regional_domain_name
    origin_id   = "defaultWebS3Origin"

    s3_origin_config {
      origin_access_identity = aws_cloudfront_origin_access_identity.cf-web.cloudfront_access_identity_path
    }
  }

  enabled             = true
  default_root_object = "index.html"

  aliases = ["www.${local.app_zone_name}", "www-test.${local.app_zone_name}"]

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD", "OPTIONS"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "defaultWebS3Origin"

    forwarded_values {
      query_string = false
      headers      = ["x-blue-green-context"]
      cookies {
        forward = "none"
      }
    }

    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
    viewer_protocol_policy = "allow-all"

    # Note when using lambda functions on the edge like this, Terraform will fail
    # to remove them until a few hours after the Cloudfront or associations are
    # deleted.  See https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/lambda-edge-delete-replicas.html
    lambda_function_association {
      event_type   = "viewer-request"
      lambda_arn   = aws_lambda_function.blue-green-viewer-request-edge.qualified_arn
      include_body = false
    }

    lambda_function_association {
      event_type   = "origin-request"
      lambda_arn   = aws_lambda_function.blue-green-origin-request-edge.qualified_arn
      include_body = false
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "whitelist"
      locations        = ["US"]
    }
  }

  viewer_certificate {
    acm_certificate_arn = aws_acm_certificate.cert.arn
    ssl_support_method  = "sni-only"
  }
}

data "aws_iam_policy_document" "lambda-assume-role-policy" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type = "Service"
      identifiers = [
        "edgelambda.amazonaws.com",
        "lambda.amazonaws.com"
      ]
    }
  }
}

data "aws_iam_policy_document" "lambda-execution-policy" {
  statement {
    sid    = "CloudwatchLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = ["*"]
  }
  statement {
    sid    = "EdgeCloudfront"
    effect = "Allow"
    actions = [
      "lambda:GetFunction",
      "lambda:EnableReplication*",
      "iam:CreateServiceLinkedRole",
      "cloudfront:UpdateDistribution "
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "lambda-execution-policy" {
  name   = "lambda-execution-policy"
  policy = data.aws_iam_policy_document.lambda-execution-policy.json
}

resource "aws_iam_role" "blue-green-edge-lambdas" {
  name               = "blue-green-edge-lambdas"
  assume_role_policy = data.aws_iam_policy_document.lambda-assume-role-policy.json
}

resource "aws_iam_role_policy_attachment" "blue-green-viewer-request-edge-lambda-cloudwatch" {
  role       = aws_iam_role.blue-green-edge-lambdas.name
  policy_arn = aws_iam_policy.lambda-execution-policy.arn
}

data "archive_file" "blue-green-viewer-request-edge-lambda" {
  type        = "zip"
  source_dir  = "files/lambdas/blue_green_viewer_request_edge"
  output_path = "${path.module}/blue_green_viewer_request_edge_lambda.zip"
}

resource "aws_lambda_function" "blue-green-viewer-request-edge" {
  provider         = aws.us-east-1
  function_name    = "blue-green-viewer-request-edge"
  role             = aws_iam_role.blue-green-edge-lambdas.arn
  handler          = "lambda.lambda_handler"
  filename         = data.archive_file.blue-green-viewer-request-edge-lambda.output_path
  source_code_hash = filebase64sha256("${data.archive_file.blue-green-viewer-request-edge-lambda.output_path}")
  runtime          = "python3.8"
  publish          = true
}

data "archive_file" "blue-green-origin-request-edge-lambda" {
  type        = "zip"
  source_dir  = "files/lambdas/blue_green_origin_request_edge"
  output_path = "${path.module}/blue_green_origin_request_edge_lambda.zip"
}

resource "aws_lambda_function" "blue-green-origin-request-edge" {
  provider         = aws.us-east-1
  function_name    = "blue-green-origin-request-edge"
  role             = aws_iam_role.blue-green-edge-lambdas.arn
  handler          = "lambda.lambda_handler"
  filename         = data.archive_file.blue-green-origin-request-edge-lambda.output_path
  source_code_hash = filebase64sha256("${data.archive_file.blue-green-origin-request-edge-lambda.output_path}")
  runtime          = "python3.8"
  publish          = true
}
