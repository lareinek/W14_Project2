variable "domain_name" {
  description = "Domain name to use (must exist in Route 53)"
  type        = string
  default = "lareinek-services.site"
}

variable "site_name" {
  description = "Subdomain for the site (like www)"
  type        = string
  default     = "project2"
}