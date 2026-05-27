# workflow-catalog
## Workflows
All workflows created (must be in `.github/workflows/`) are listed below in their own sections with details on their use.

### Docker Security Pipeline
This workflow's pipeline executes the following steps:
1. Verify the Dockerfile with Checkov
2. Build the Docker image 
3. Generate the Docker image's Software Bill of Materials (SBOM) using Syft
4. Store the SBOM as an artifact
5. Scan the SBOM using Grype
6. Push the image to GitHub as a repository package (if `main` branch, or `docker-security-pipeline branch`)
7. Push the image to DockerHub (`main` branch only)

The following points should be noted:
- In order to execute the pipeline, the Dockerfile should be in the root directory of the repository
- For steps 1 or 5, should either scan fail, the pipeline will stop at that step 
- In order to push to DockerHub, the `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` variables must be set in the repository's Secrets on GitHub (via Settings tab on repository). `DOCKERHUB_TOKEN` is Personal Access Token (PAT) which is generated via Account Settings > Security > New Access Token on DockerHub (with Read & Write permissions)

### gitleaks
Requires a license from [gitleaks.io](https://gitleaks.io/). This license must be added as a GitHub secret under the name '`GITLEAKS_LICENSE`' which, if required across multiple repositories, should be an organisation-level secret (see [here](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-secrets#creating-secrets-for-an-organization) for details on how to create). Currently on the workflow-catalog repository, a secret has been created at the repository level for testing (creation method can be found [here](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-secrets#creating-secrets-for-a-repository)).

Currently, the workflow is set up to run on every pull request, push, and workflow dispatch (see [gitleaks.yml](https://github.com/CSC-Operations-Coordination-Service/workflow-catalog/blob/gitleaks-workflow/.github/workflows/gitleaks.yml))

#### Setting up the pre-commit hook
In order to run gitleaks upon a local commit, `pre-commit` must be installed (see [here](https://pre-commit.com/#install) for more details):
```sh
apt install pre-commit
# or
pip install pre-commit
# or
brew install pre-commit
```
Then follow the instructions [here](https://github.com/gitleaks/gitleaks#pre-commit) to install the pre-commit hook (`.pre-commit-config.yaml` must be created). If properly followed, when creating a commit locally, `pre-commit` will scan the changes with gitleaks and prevent the commit in the case of security failures.

For example, creating a file, '`test_sensitive_data.yml`', in the local repository with the following contents:

```yml
username: testuser
id: "123456"
nickname: "Software Engineer"
token: "82a53bc7-1455-9874-21ab-dc83ab9786ac"
```

If the newly created file is then staged and a commit is attempted:

```sh
$ git commit -m "this commit contains a secret"
[WARNING] Unstaged files detected.
[INFO] Stashing unstaged files to /home/simon/.cache/pre-commit/patch1779379262-28553.
[INFO] Initializing environment for https://github.com/gitleaks/gitleaks.
[INFO] Installing environment for https://github.com/gitleaks/gitleaks.
[INFO] Once installed this environment will be reused.
[INFO] This may take a few minutes...
Detect hardcoded secrets.................................................Failed
- hook id: gitleaks
- exit code: 1

○
    │╲
    │ ○
    ○ ░
    ░    gitleaks

Finding:     ..."Software Engineer"
token: "REDACTED"
Secret:      REDACTED
RuleID:      generic-api-key
Entropy:     3.697160
File:        test_sensitive_data.yml
Line:        4
Fingerprint: test_sensitive_data.yml:generic-api-key:4

5:01PM INF 0 commits scanned.
5:01PM INF scanned ~107 bytes (107 bytes) in 32.1ms
5:01PM WRN leaks found: 1

[INFO] Restored changes from /home/simon/.cache/pre-commit/patch1779379262-28553.
```

Gitleaks ensures the commit fails and is not committed locally ('shift-left' security).

#### Excluding specific lines from gitleaks
In case we want to exclude a specific line from scanning by gitleaks, create a `.gitleaksignore` file at the root of your repository and add hte 'fingerprint' of this line to that file.

For example, in this `README.md` file, there is an example 'sensitive' password in the section above. To have gitleaks ignore this, determine the exact fingerprint by attempting the commit, and then extracting the Fingerprint from the failure output. In the case of this README, the Fingerprint is:

```txt
README.md:generic-api-key:27
```