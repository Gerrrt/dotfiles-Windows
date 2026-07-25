-- ================================================================================================
-- TITLE : terraform-ls (Terraform / HCL LSP Setup)
-- LINKS : https://github.com/hashicorp/terraform-ls
-- ABOUT : HashiCorp's Terraform language server — completion, diagnostics, gotos, codelens. cmd
--         `{ "terraform-ls", "serve" }`, .terraform/.git root_markers, and the codelens on_attach
--         come from nvim-lspconfig's lsp/terraformls.lua (a table cmd, so the binary-availability
--         guard reads it directly).
-- INSTALL: mason — "terraform-ls" (Go binary). Formatter: `terraform fmt` via conform's
--         terraform_fmt — needs the `terraform` (or `tofu`) binary on PATH (not Mason-managed).
--         Linter: tflint (nvim-lint, gated on .tflint.hcl).
-- ================================================================================================
-- filetypes stays terraform/terraform-vars (as lspconfig ships it): terraform-ls is
-- Terraform-specific, so it is NOT attached to generic `hcl` buffers (Packer/Nomad/Vault) —
-- those still get treesitter highlighting and `terraform fmt` formatting (conform), just no LSP.
return {
	filetypes = { "terraform", "terraform-vars" },
}
