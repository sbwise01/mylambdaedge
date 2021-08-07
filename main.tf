terraform {
  required_version = "~> 0.12.31"

  backend "s3" {
    bucket  = "bw-terraform-state-us-east-1"
    key     = "edgelambda.tfstate"
    region  = "us-east-1"
    profile = "foghorn-io-brad"
  }
}

provider "aws" {
  region = "us-east-2"
}

provider "aws" {
  alias  = "us-east-1"
  region = "us-east-1"
}

resource "aws_route53_zone" "parent_zone" {
  name              = "aws.bradandmarsha.com"
  delegation_set_id = "N03386422VXZJKGR4YO18"
}

resource "aws_route53_record" "live" {
  zone_id = aws_route53_zone.parent_zone.zone_id
  name    = "www"
  type    = "A"
  alias {
    name                   = aws_cloudfront_distribution.cf-web.domain_name
    zone_id                = aws_cloudfront_distribution.cf-web.hosted_zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "test" {
  zone_id = aws_route53_zone.parent_zone.zone_id
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
  domain_name               = "aws.bradandmarsha.com"
  subject_alternative_names = ["*.aws.bradandmarsha.com"]
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
  zone_id         = aws_route53_zone.parent_zone.zone_id
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "cert" {
  provider                = aws.us-east-1
  certificate_arn         = aws_acm_certificate.cert.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

resource "aws_s3_bucket" "brad-web-bucket" {
  bucket        = "brad-web-bucket"
  acl           = "public-read"
  force_destroy = true
  website {
    error_document = "error.html"
    index_document = "index.html"
  }
}

resource "aws_s3_bucket_object" "default-index-page" {
  bucket        = aws_s3_bucket.brad-web-bucket.id
  acl           = "public-read"
  force_destroy = true
  key           = "index.html"
  source        = "files/web/index.html"
  content_type  = "text/html"

  etag = filemd5("files/web/index.html")
}

resource "aws_s3_bucket_object" "blue-index-page" {
  bucket        = aws_s3_bucket.brad-web-bucket.id
  acl           = "public-read"
  force_destroy = true
  key           = "blue/index.html"
  source        = "files/web/blue/index.html"
  content_type  = "text/html"

  etag = filemd5("files/web/blue/index.html")
}

resource "aws_s3_bucket_object" "green-index-page" {
  bucket        = aws_s3_bucket.brad-web-bucket.id
  acl           = "public-read"
  force_destroy = true
  key           = "green/index.html"
  source        = "files/web/green/index.html"
  content_type  = "text/html"

  etag = filemd5("files/web/green/index.html")
}

resource "aws_s3_bucket" "brad-static-content-bucket" {
  bucket        = "brad-static-content-bucket"
  acl           = "public-read"
  force_destroy = true
  website {
    error_document = "error.html"
    index_document = "index.html"
  }
}

resource "aws_s3_bucket_object" "blue-image" {
  bucket        = aws_s3_bucket.brad-static-content-bucket.id
  acl           = "public-read"
  force_destroy = true
  key           = "blue/image.jpg"
  source        = "files/static_content/blue/image.jpg"
  content_type  = "image/jpeg"

  etag = filemd5("files/static_content/blue/image.jpg")
}

resource "aws_s3_bucket_object" "green-image" {
  bucket        = aws_s3_bucket.brad-static-content-bucket.id
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
    domain_name = aws_s3_bucket.brad-web-bucket.bucket_regional_domain_name
    origin_id   = "defaultWebS3Origin"

    s3_origin_config {
      origin_access_identity = aws_cloudfront_origin_access_identity.cf-web.cloudfront_access_identity_path
    }
  }

  origin {
    domain_name = aws_s3_bucket.brad-web-bucket.bucket_regional_domain_name
    origin_id   = "blueWebS3Origin"
    #origin_path = "/blue"

    s3_origin_config {
      origin_access_identity = aws_cloudfront_origin_access_identity.cf-web.cloudfront_access_identity_path
    }
  }

  origin {
    domain_name = aws_s3_bucket.brad-web-bucket.bucket_regional_domain_name
    origin_id   = "greenWebS3Origin"
    #origin_path = "/green"

    s3_origin_config {
      origin_access_identity = aws_cloudfront_origin_access_identity.cf-web.cloudfront_access_identity_path
    }
  }

  enabled             = true
  default_root_object = "index.html"

  aliases = ["www.aws.bradandmarsha.com", "www-test.aws.bradandmarsha.com"]

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD", "OPTIONS"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "defaultWebS3Origin"

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }

    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
    viewer_protocol_policy = "allow-all"
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
