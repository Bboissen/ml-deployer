# AWS security policy

- The standalone-account operator uses the MFA-protected `sposhfi-admin` IAM console user and AWS CLI `aws login`. Static access keys are rejected.
- Later OpenTofu roots assume a keyless deployer role; EC2 uses instance profiles.
- No EC2 key pair or inbound security-group rule exists. Administration uses SSM Session Manager.
- Require IMDSv2, encrypted EBS, account-level S3 Block Public Access, private bucket policies, and no ACL-based public access.
- User data, plans, state, logs, and receipts contain no credentials, login cache tokens, signed URLs, or contact/payment data.
- Exactly one active instance is permitted. Live compute requires an external one-time deadline and local self-termination fallback.
- Direct root/workspace disks auto-delete. Spot may preserve one tagged run-scoped workspace only until terminal cleanup.
- Persistent roots use `prevent_destroy` and have no routine destroy target.
- Every authorization will bind exact account, Region, root, profile, plan SHA-256, cost, expiry, and one-use nonce.
