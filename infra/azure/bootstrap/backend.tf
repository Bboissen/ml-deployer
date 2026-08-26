terraform {
  # The backend bootstrap cannot depend on the Blob backend it creates.
  backend "local" {}
}
