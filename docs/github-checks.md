# Pull request checks and merge protection

Every pull request runs these workflows, including documentation-only changes:

| Workflow | Required status check name | What it checks |
| --- | --- | --- |
| Android | `Android build and tests` | Dart analysis, Flutter application and connectivity adapter tests, a debug APK build, native Android app and connectivity unit tests |
| iOS prototype | `ios` | Signing helper tests, iOS Simulator build and native Swift protocol tests |

Both workflows also support manual runs once their files are on the default
branch. They cancel an older run when the same pull request receives new commits.
The signed **iOS TestFlight** workflow is manual and is not a merge requirement.

The Android build uses Flutter 3.35.7 and Java 17 on a standard Ubuntu runner.
Dependencies for the app, connectivity tests and transport lab are installed
before analysis, which also visits the nested Dart projects on a clean checkout.
Flutter generates the ignored Gradle wrapper before the native tests run. No
Android signing secrets are needed. APKs are built but not uploaded on every PR;
native Android test reports are retained for three days on failure. These checks
do not exercise physical NFC or Wi-Fi connections.

## Require successful checks before merging into master

Adding workflow YAML only runs checks; merge protection is a separate repository
setting. The default branch in this repository is `master`.

1. Push the implementation branch and open a pull request targeting `master`.
   Wait for both checks to run at least once so GitHub can suggest their names.
2. Open the repository's [rules settings](https://github.com/jkaleba/SkyChat/settings/rules)
   and select **New ruleset** > **New branch ruleset**.
3. Name it `Protect master`, set **Enforcement status** to **Active**, and leave
   the **Bypass list** empty so administrators also follow the merge rules.
4. Under **Target branches**, choose **Add target** > **Include default branch**.
5. Enable **Require a pull request before merging**. Set required approvals to
   **0** if you work alone; your own pull request cannot be approved by you.
6. Enable **Require status checks to pass** and add these exact check names:
   `Android build and tests` and `ios`. Choose **GitHub Actions** as their source
   when offered. Names identify jobs, not workflows: do not add `Android`,
   `iOS prototype` or the manual TestFlight job `build` as required checks.
7. Enable **Require branches to be up to date before merging**, keep
   **Block force pushes** enabled, then select **Create**.

A failed, missing, cancelled or still-running required check prevents merging.
Update the PR branch when `master` changes, then wait for the checks again.
If an existing rule already requires checks, edit that rule instead of creating
conflicting requirements. Keep these job names stable, or update the ruleset
whenever you rename them. These workflows do not use path filters or job-level
skip conditions, so a documentation change still produces the required checks.

See GitHub's [ruleset setup](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/creating-rulesets-for-a-repository)
and [required status checks](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets#require-status-checks-to-pass-before-merging).

## Actions allowances

SkyChat is public, so standard Ubuntu and macOS runner execution is free here.
Larger runners are charged separately.

For private repositories, **GitHub Pro includes USD 18 of compute per month**,
about **3,000 standard Linux minutes** at USD 0.006/minute. macOS consumes this
allowance faster at USD 0.062/minute. Academic Pro uses the same plan allowances.
Usage is charged to the repository owner.

Pro includes **1 GB of artifact storage** shared with GitHub Packages and a
separate **10 GB cache allowance per repository**. Free public runner execution
does not provide unlimited artifact storage. Short retention, avoiding per-PR
APK uploads and cancelling obsolete runs help keep usage down.

Check your actual plan and usage under [account billing](https://github.com/settings/billing).
For paid usage, use **Budgets and alerts** to set an Actions budget and enable
**Stop usage when budget limit is reached**; an alert-only budget does not stop
spending. Without a valid payment method GitHub blocks additional compute after
the included allowance is consumed.

Pricing checked on 2026-11-25 against GitHub's
[Actions billing documentation](https://docs.github.com/en/billing/concepts/product-billing/github-actions)
and [budget instructions](https://docs.github.com/en/billing/how-tos/set-up-budgets).
