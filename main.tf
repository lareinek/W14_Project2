# S3 Bucket for static website hosting
resource "aws_s3_bucket" "static_site" {
  bucket = "${var.site_name}.${var.domain_name}" # Ex: project2.lareinek-services.site
  force_destroy = true                           # Supprime le contenu du bucket apres terraform destroy
}

# Active le contrôle de propriété pour que les fichiers soient bien gérés par le propriétaire du bucket
resource "aws_s3_bucket_ownership_controls" "controls" {
  bucket = aws_s3_bucket.static_site.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Permet de rendre le bucket public 
resource "aws_s3_bucket_public_access_block" "public_access" {
  bucket = aws_s3_bucket.static_site.id
  block_public_acls   = false
  block_public_policy = false
  ignore_public_acls  = false
  restrict_public_buckets = false
}

# Ajout d'un Origin Access Control (OAC)
resource "aws_cloudfront_origin_access_control" "oac" {
  name                              = "s3-oac"
  description                       = "Access control for S3 bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}


# Téléversement automatique de tous les fichiers du dossier local schoolstatic
resource "aws_s3_object" "static_files" {
  for_each = fileset("${path.module}/schoolstatic", "**")   # fileset (canne tous les fichiers de ton dossier) for_each (crée un objet S3 pour chaque fichier)
  bucket   = aws_s3_bucket.static_site.id
  key      = each.value
  source   = "${path.module}/schoolstatic/${each.value}"
  etag     = filemd5("${path.module}/schoolstatic/${each.value}") #calcule un hash pour re-téléverser seulement les fichiers modifiés.
  content_type = lookup(
    {
      html = "text/html",
      css  = "text/css",
      js   = "application/javascript",
      png  = "image/png",
      jpg  = "image/jpeg",
      jpeg = "image/jpeg",
      svg  = "image/svg+xml"
    },
    element(split(".", each.value), length(split(".", each.value)) - 1),
    "application/octet-stream"
  )
}

# ACM Certificate (must be in us-east-1 for CloudFront)
resource "aws_acm_certificate" "cert" {
  domain_name       = "${var.site_name}.${var.domain_name}" # Ex: project2.lareinek-services.site
  validation_method = "DNS"                                 #Validation DNS permet à AWS de vérifier que le domaine m’appartient.
}

# DNS validation record (l’enregistrement DNS pour valider le certificat)
resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.cert.domain_validation_options : dvo.domain_name => {
      name  = dvo.resource_record_name
      type  = dvo.resource_record_type
      value = dvo.resource_record_value
    }
  }

  zone_id = data.aws_route53_zone.main.zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.value]
  ttl     = 60
}

data "aws_route53_zone" "main" {
  name         = var.domain_name
  private_zone = false
}

resource "aws_acm_certificate_validation" "cert_validation_complete" {
  certificate_arn         = aws_acm_certificate.cert.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

# CloudFront Distribution
resource "aws_cloudfront_distribution" "cdn" {
  origin {
    domain_name = aws_s3_bucket.static_site.bucket_regional_domain_name
    origin_id   = "s3-origin"
    origin_access_control_id = aws_cloudfront_origin_access_control.oac.id
  }

  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"              # Page d’accueil par défaut

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "s3-origin"
    viewer_protocol_policy = "redirect-to-https"   # Redirige HTTP → HTTPS

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }
  }

  viewer_certificate {
    acm_certificate_arn = aws_acm_certificate_validation.cert_validation_complete.certificate_arn
    ssl_support_method  = "sni-only"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  aliases = ["${var.site_name}.${var.domain_name}"]      # Mon nom de domaine
}

resource "aws_s3_bucket_policy" "private_policy" {
  bucket = aws_s3_bucket.static_site.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "cloudfront.amazonaws.com"
      }
      Action = "s3:GetObject"
      Resource = "${aws_s3_bucket.static_site.arn}/*"
      Condition = {
        StringEquals = {
          "AWS:SourceArn" = aws_cloudfront_distribution.cdn.arn
        }
      }
    }]
  })
}

# Route 53 Alias record for CloudFront (mon domaine pointe vers CloudFront)
resource "aws_route53_record" "alias" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "${var.site_name}.${var.domain_name}"
  type    = "A"                                          #A(Alias)

  alias {
    name                   = aws_cloudfront_distribution.cdn.domain_name
    zone_id                = aws_cloudfront_distribution.cdn.hosted_zone_id
    evaluate_target_health = false
  }
}
