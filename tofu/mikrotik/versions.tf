terraform {
  required_version = ">= 1.10.0"

  required_providers {
    routeros = {
      source  = "terraform-routeros/routeros"
      version = "~> 1.99"
    }
  }

  # Local state, gitignored. See BOOTSTRAP.md § State — a remote backend in the
  # cluster would make the router depend on the thing it routes for.
}
