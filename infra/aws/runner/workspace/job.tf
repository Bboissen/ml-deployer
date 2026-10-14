# Run Command carries only public job settings. The reviewed document always
# drops privileges before fetching the Git credential or invoking repository code.
variable "workspace_job_timeout_seconds" {
  type    = number
  default = 900
  validation {
    condition     = var.workspace_job_timeout_seconds == floor(var.workspace_job_timeout_seconds) && var.workspace_job_timeout_seconds >= 30 && var.workspace_job_timeout_seconds <= 1800
    error_message = "The workload execution timeout must be 30 through 1800 seconds."
  }
}

locals {
  # Source is part of the immutable reviewed SSM document, keeping the EC2
  # bootstrap below its 16 KiB limit. The document drops privileges first.
  job_dispatch = <<-PYTHON
import base64,json,sys,subprocess
job=json.loads(base64.b64decode(sys.argv[1],validate=True))
if 'commands' in job:
    __file__='/opt/workspace/scripts/aws/workspace-generic-job.py'
    exec(compile(base64.b64decode('${filebase64("${path.module}/../../../../scripts/aws/workspace-generic-job.py")}'),'reviewed-generic-job','exec'))
    sys.exit(run(job))
sys.exit(subprocess.call(['bash','/opt/workspace/scripts/aws/workspace-job.sh',sys.argv[1]]))
PYTHON
}

resource "aws_ssm_document" "job" {
  name            = "${local.role_name}-job"
  document_type   = "Command"
  document_format = "JSON"
  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Execute a pinned workspace repository as the non-root workspace user"
    parameters = {
      job = { type = "String", allowedPattern = "^[A-Za-z0-9+/=]+$", minChars = 1, maxChars = 16384 }
    }
    mainSteps = [{
      action = "aws:runShellScript", name = "workspaceJob"
      inputs = {
        timeoutSeconds = tostring(var.workspace_job_timeout_seconds + 30)
        runCommand     = ["exec /usr/sbin/runuser -u workspace -- /usr/bin/env -i HOME=/home/workspace PATH=/opt/workspace/sdk/bin:/usr/local/bin:/usr/bin:/bin /opt/workspace/sdk/bin/python -c 'exec(__import__(\"base64\").b64decode(\"${base64encode(local.job_dispatch)}\"))' '{{ job }}'"]
      }
    }]
  })
}
