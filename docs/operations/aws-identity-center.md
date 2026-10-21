# IAM Identity Center sign-in

Console sign-in (`aws login`) ends after at most 12 hours, so an unattended job
queue that outlives it stops at its next AWS call. IAM Identity Center keeps one
browser sign-in valid for the whole access-portal session, from 15 minutes up
to 90 days. While that session is valid, the AWS CLI and SDK renew role
credentials silently through its refresh token. No static access keys are
involved, and profiles with long-lived keys stay refused.

## How it fits together

```text
Identity Center user (portal session, e.g. 30 days)
  -> permission set MlDeployerOperator (12 h credentials, may only assume the role below)
    -> IAM role ml-deployer-operator (operator; stable ARN)
      -> each workspace's deployer role (unchanged)
```

Deploy attaches a per-run, lease-bound terminal grant to its operator. AWS
does not allow changes to the roles Identity Center creates
(`AWSReservedSSO_*`), so Deploy refuses them as operators. The command below
creates an owner-managed role instead. Its trust accepts only the reserved
role of that one permission set, and its ARN survives permission-set
re-provisioning. The role holds `AdministratorAccess`, the same access an
administrator's console identity has today; a narrower operator policy
remains [native acceptance](aws-native-acceptance.md) work.

## Owner prerequisites (console only)

These steps have no public API. `./workspace identity-center` checks the
account and prints the exact next step until everything is ready.

1. **Organization.** In the management account, open AWS Organizations and
   choose *Create an organization*. A one-account organization changes no
   billing.
2. **Identity Center organization instance.** Open IAM Identity Center in the
   chosen region, choose *Enable*, then *Enable* again on *Enable IAM Identity
   Center with AWS Organizations*. An account instance cannot grant AWS account
   access.
3. **Portal session.** *Settings → Authentication → Session duration* (newer
   consoles: *User interactive sessions*) *→ Configure*, then choose the length,
   for example 30 days.
4. **First sign-in email.** *Settings → Authentication → Standard
   authentication → Configure → Send email OTP*. Users created through the API
   then receive a verification email on first sign-in.
5. **MFA.** Keep *Require them to register an MFA device at sign in*.

## Set up

Run this with an existing administrator profile in the management account
(console or SSO sign-in):

```sh
./workspace identity-center --profile ADMIN_PROFILE --region us-east-1 --user NAME \
  --email you@example.com --display-name "Given Family"
```

The command shows the remaining changes and a scope hash, then applies them
after one interactive confirmation, or noninteractively with
`--authorization "approve scope HASH"`:

- the Identity Center user (when absent);
- permission set `MlDeployerOperator` (`PT12H`) with an inline policy that
  allows only `sts:AssumeRole` on `ml-deployer-operator`;
- role `ml-deployer-operator`, its trust and `AdministratorAccess`;
- the account assignment for the user;
- three new `~/.aws/config` sections: `[sso-session ml-deployer-sso]`,
  `[profile ml-deployer-sso-portal]` and `[profile ml-deployer-sso]` (operator
  role via the portal profile). Existing sections are never edited; a different
  existing section with the same name stops the command. `--new-profile`
  chooses other names.

A rerun with the same arguments changes nothing. An existing role or
permission set with unexpected settings stops the command rather than being
overwritten. Each apply leaves a receipt under
`evidence/aws/identity-center/`. Add `--start-url` if the portal URL was
customized, `--days` if the session is not 30 days, and `--settings-confirmed`
when no terminal can answer the console-settings question.

Then the user signs in once:

1. Open the printed access-portal URL and sign in with the user name. Enter the
   emailed code, set a password and register MFA.
2. On the workstation, run `./workspace login --profile ml-deployer-sso --region
   us-east-1`. It runs `aws sso login` for the portal profile; add `--remote`
   for a browser on another device.
3. `./workspace auth-check --profile ml-deployer-sso --region us-east-1` shows
   `assumed-role/ml-deployer-operator/NAME`.

Use `"profile": "ml-deployer-sso"` in project files.

## Session length trade-off

| Setting | Effect |
| --- | --- |
| Portal session (console setting) | One browser sign-in lasts this long. Jobs fail at their next AWS call after it ends; run `./workspace login` again. |
| Permission set `PT12H` | Lifetime of each role credential; renewed silently while the portal session is valid. |
| Operator role (role chaining) | One hour per credential; the CLI and SDK re-assume it from the portal credentials automatically. |

The provider-side expiry guard still terminates each workspace at its reviewed
deadline, whatever the sign-in state.

## Security note

For the whole portal session, anyone who can use this workstation account,
including its processes and agents, can deploy as the operator. Choose the
shortest session that covers your unattended work, keep the workstation
account private, and end a session early with `aws sso logout` locally or in
Identity Center (*Users → NAME → Active sessions*). Deleting the user's
account assignment revokes access at the next credential renewal.

## Moving an existing workspace to the new operator

A retained foundation trusts exactly one operator ARN. The first deploy review
with the new profile detects the change and adds one line:

```text
operator:    rebind the retained deployer trust from <old ARN> to <new ARN>
```

That step is bound to the same scope hash as the rest of the review. When
authorized, it plans `aws_iam_role.deployer` and `aws_iam_role_policy.deployer`
only, against the retained platform state. The plan is accepted only if it
changes the deployer trust's AWS principal from the old operator to the new
one, and the `DenyReviewedOperatorPolicyMutation` resource the same way.
Every other attribute and statement must be identical, and the live trust and
policy must still match the plan before apply. Recovery after an interruption
finishes exactly that change. Launch evidence follows the rebinding edge back
to the original platform plan; any other operator change in the chain is
refused. After the rebind, the old operator can no longer assume the deployer.

Steps:

1. Wait until no operation of the project is running or interrupted. Finish
   `resume` or `cancel` with the old profile first; old operations cannot
   assume the deployer after the rebind. The review also refuses while any
   covered compute exists.
2. Change `"profile"` in the project file to the new profile.
3. Run `./workspace PROJECT.json`, check the `operator:` line and confirm
   interactively once. Noninteractive runs need the new scope hash; an
   authorization from an earlier review does not match.
4. Later runs reuse the rebound foundation without further changes.

A pending deployer IAM tightening must be applied with the original operator
before rebinding. Re-onboarding under a new project name also works, but it
creates a second foundation and uploads the dataset again.
