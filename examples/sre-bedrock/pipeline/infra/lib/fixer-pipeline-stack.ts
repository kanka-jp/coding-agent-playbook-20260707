import { CfnOutput, Duration, RemovalPolicy, Stack, StackProps } from "aws-cdk-lib";
import { Construct } from "constructs";
import * as s3 from "aws-cdk-lib/aws-s3";
import * as codebuild from "aws-cdk-lib/aws-codebuild";
import * as secretsmanager from "aws-cdk-lib/aws-secretsmanager";
import * as iam from "aws-cdk-lib/aws-iam";
import * as events from "aws-cdk-lib/aws-events";
import * as targets from "aws-cdk-lib/aws-events-targets";

export interface FixerPipelineStackProps extends StackProps {
  /** Target repo "<owner>/<repo>". fixer clones here and creates PR */
  readonly targetRepo: string;
  /** Broken-state branch (fix starting point) */
  readonly targetBranch: string;
  /** PR base branch */
  readonly prBase: string;
  /** anthropic=direct API key, bedrock=via AWS Bedrock */
  readonly backend: "anthropic" | "bedrock";
  /** For backend=anthropic, API model id; for bedrock, inference profile id */
  readonly anthropicModel: string;
  /** repo containing fixer-entrypoint.sh (default = targetRepo; point to playbook for fixing different app) */
  readonly entrypointRepo: string;
  /** ref of fixer-entrypoint.sh (default main; not tied to default branch) */
  readonly entrypointRef: string;
}

/**
 * ADR cloud-unattended-sre.md pattern A "minimal e2e" infrastructure:
 *   PUT sanitized triage to S3  ->  EventBridge  ->  CodeBuild(fixer identity) runs
 *   fixer-entrypoint.sh (direct key for backend=anthropic / AWS Bedrock for backend=bedrock)  ->  PR.
 * Automatic CloudWatch alarm → Lambda(observation) wiring added on top (pipeline/README.md). This stack
 * is the phase to verify "fixer runs on real AWS and PR is created" at minimal cost.
 */
export class FixerPipelineStack extends Stack {
  constructor(scope: Construct, id: string, props: FixerPipelineStackProps) {
    super(scope, id, props);

    // Sanitized triage handoff bucket (observation PUTs, fixer GETs; sole input path).
    // Enable EventBridge notification to catch S3 ObjectCreated in rule.
    const triageBucket = new s3.Bucket(this, "TriageBucket", {
      eventBridgeEnabled: true,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      encryption: s3.BucketEncryption.S3_MANAGED,
      enforceSSL: true,
      removalPolicy: RemovalPolicy.DESTROY,
      autoDeleteObjects: true,
    });

    // GitHub token needed for both backends. Anthropic key created only for backend=anthropic
    // (bedrock path allows InvokeModel via IAM, key not needed). Host loads values with put-secret-value.
    const githubTokenSecret = new secretsmanager.Secret(this, "FixerGithubToken", {
      description: "repo-scoped GitHub token fixer uses for clone/push/PR (loaded by host)",
    });
    const anthropicKeySecret =
      props.backend === "anthropic"
        ? new secretsmanager.Secret(this, "AnthropicApiKey", {
            description: "fixer's ANTHROPIC_API_KEY (host loads real value with put-secret-value)",
          })
        : undefined;

    const baseEnvVars: { [name: string]: codebuild.BuildEnvironmentVariable } = {
      BACKEND: { value: props.backend },
      ANTHROPIC_MODEL: { value: props.anthropicModel },
      TARGET_REPO: { value: props.targetRepo },
      TARGET_BRANCH: { value: props.targetBranch },
      PR_BASE: { value: props.prBase },
      ENTRYPOINT_REPO: { value: props.entrypointRepo },
      ENTRYPOINT_REF: { value: props.entrypointRef },
      // bucket is static (set at deploy time). key is overridden per-build by EventBridge.
      TRIAGE_BUCKET: { value: triageBucket.bucketName },
      TRIAGE_S3_KEY: { value: "" },
      // secret values passed as ARN only, not constantly in env; fetched in build phase after install complete
      // (don't expose GH_TOKEN to unfixed code during install phase).
      GH_SECRET_ARN: { value: githubTokenSecret.secretArn },
    };
    if (anthropicKeySecret) {
      baseEnvVars.ANTHROPIC_SECRET_ARN = { value: anthropicKeySecret.secretArn };
    }

    const buildCommands: string[] = [
      // Fetch secrets in build phase after install (don't expose to unfixed code during install).
      'export GH_TOKEN=$(aws secretsmanager get-secret-value --secret-id "$GH_SECRET_ARN" --query SecretString --output text)',
    ];
    if (anthropicKeySecret) {
      buildCommands.push(
        'export ANTHROPIC_API_KEY=$(aws secretsmanager get-secret-value --secret-id "$ANTHROPIC_SECRET_ARN" --query SecretString --output text)'
      );
    }
    buildCommands.push(
      'test -n "$TRIAGE_S3_KEY" || { echo "ERROR: TRIAGE_S3_KEY not set (EventBridge override)" >&2; exit 1; }',
      'aws s3 cp "s3://$TRIAGE_BUCKET/$TRIAGE_S3_KEY" /tmp/triage.json',
      'git config --global user.email "sre-fixer@users.noreply.github.com"',
      'git config --global user.name "SRE Fixer (unattended)"',
      // Don't embed token in clone URL: authenticate push/clone via gh credential helper. This prevents token
      // staying in /work/.git/config, blocking the path for claude -p Read to extract token from .git/config.
      "gh auth setup-git",
      // Fetch entrypoint with explicit ref (default main) to avoid default-branch dependency. Target repo fetched at broken branch to /work.
      'git clone --depth 1 --branch "$ENTRYPOINT_REF" "https://github.com/$ENTRYPOINT_REPO.git" /tmp/src',
      'git clone "https://github.com/$TARGET_REPO.git" /work',
      'git -C /work checkout "$TARGET_BRANCH"',
      // BACKEND / ANTHROPIC_MODEL / ANTHROPIC_API_KEY reach entrypoint via env (inline reassignment doesn't override backend).
      'cd /work && PR_BASE="$PR_BASE" TRIAGE_PATH=/tmp/triage.json bash /tmp/src/examples/sre-bedrock/pipeline/fixer-entrypoint.sh'
    );

    // CodeBuild running fixer. Has no source (NO_SOURCE), buildspec clones it.
    const fixerProject = new codebuild.Project(this, "FixerProject", {
      timeout: Duration.minutes(20),
      environment: {
        buildImage: codebuild.LinuxBuildImage.STANDARD_7_0,
        computeType: codebuild.ComputeType.SMALL,
      },
      environmentVariables: baseEnvVars,
      buildSpec: codebuild.BuildSpec.fromObject({
        version: "0.2",
        phases: {
          install: {
            commands: [
              // claude CLI pinned version (supply-chain risk mitigation; no secret in this phase env).
              "npm install -g @anthropic-ai/claude-code@2.1.196",
              // Install gh as pinned binary if missing (CodeBuild standard image sometimes lacks gh).
              'type gh >/dev/null 2>&1 || { curl -fsSL https://github.com/cli/cli/releases/download/v2.62.0/gh_2.62.0_linux_amd64.tar.gz | tar xz -C /tmp && install -m755 /tmp/gh_2.62.0_linux_amd64/bin/gh /usr/local/bin/gh; }',
            ],
          },
          build: {
            commands: buildCommands,
          },
        },
      }),
    });

    // ---- fixer identity permission boundary (CDK version of fixer-identity-iam.json) ----
    // GET only own secrets (GitHub token, + direct key for backend=anthropic) (for build phase get-secret-value).
    githubTokenSecret.grantRead(fixerProject);
    if (anthropicKeySecret) {
      anthropicKeySecret.grantRead(fixerProject);
    }
    // For backend=bedrock, replace direct key with ALLOW InvokeModel on both profile + foundation model.
    // Restrict foundation model to profile path only (defense-in-depth against direct invoke).
    //   https://docs.aws.amazon.com/bedrock/latest/userguide/inference-profiles-prereq.html
    if (props.backend === "bedrock") {
      // Extract provider onwards (= foundation model id) from <region-prefix>.<provider>.<model>.
      // Don't hard-code region prefix, use generic pattern in case future additions.
      const match = props.anthropicModel.match(/^(?:[a-z][a-z0-9-]*)\.(anthropic\..+)$/);
      if (!match) {
        throw new Error(
          `For backend=bedrock, anthropicModel must be inference profile id (example: global.anthropic.claude-opus-4-6-v1): ${props.anthropicModel}`
        );
      }
      const foundationModelId = match[1];
      const inferenceProfileArn = `arn:aws:bedrock:*:${this.account}:inference-profile/${props.anthropicModel}`;
      fixerProject.addToRolePolicy(
        new iam.PolicyStatement({
          effect: iam.Effect.ALLOW,
          actions: ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"],
          resources: [inferenceProfileArn],
        })
      );
      fixerProject.addToRolePolicy(
        new iam.PolicyStatement({
          effect: iam.Effect.ALLOW,
          actions: ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"],
          resources: [`arn:aws:bedrock:*::foundation-model/${foundationModelId}`],
          conditions: {
            StringLike: {
              "bedrock:InferenceProfileArn": inferenceProfileArn,
            },
          },
        })
      );
    }
    // GET one triage (deny bucket enumeration; read only key passed via event).
    triageBucket.grantRead(fixerProject, "triage/*");
    fixerProject.addToRolePolicy(
      new iam.PolicyStatement({
        effect: iam.Effect.DENY,
        actions: ["s3:ListBucket", "s3:ListBucketVersions"],
        resources: [triageBucket.bucketArn],
      })
    );
    // Explicit Deny on incident/app data read (observation's job; fixer doesn't touch).
    fixerProject.addToRolePolicy(
      new iam.PolicyStatement({
        effect: iam.Effect.DENY,
        actions: [
          "logs:StartQuery",
          "logs:GetQueryResults",
          "logs:GetLogRecord",
          "logs:FilterLogEvents",
          "logs:GetLogEvents",
          "logs:StartLiveTail",
          "cloudwatch:GetMetricData",
          "cloudwatch:GetMetricStatistics",
        ],
        resources: ["*"],
      })
    );
    // Credential broker Deny (block privilege escalation, observation role hijack).
    fixerProject.addToRolePolicy(
      new iam.PolicyStatement({
        effect: iam.Effect.DENY,
        actions: [
          "sts:AssumeRole",
          "sts:AssumeRoleWithWebIdentity",
          "sts:AssumeRoleWithSAML",
          "sts:GetFederationToken",
          "sts:GetSessionToken",
        ],
        resources: ["*"],
      })
    );

    // ---- S3 ObjectCreated(triage/*) -> EventBridge -> CodeBuild StartBuild ----
    // Startup is infra (not observation credentials). Override reaching fixer is only event-derived TRIAGE_S3_KEY.
    new events.Rule(this, "TriageObjectCreatedRule", {
      eventPattern: {
        source: ["aws.s3"],
        detailType: ["Object Created"],
        detail: {
          bucket: { name: [triageBucket.bucketName] },
          object: { key: [{ prefix: "triage/" }] },
        },
      },
      targets: [
        new targets.CodeBuildProject(fixerProject, {
          event: events.RuleTargetInput.fromObject({
            // Only event-derived object key in StartBuild environmentVariablesOverride.
            environmentVariablesOverride: [
              {
                name: "TRIAGE_S3_KEY",
                type: "PLAINTEXT",
                value: events.EventField.fromPath("$.detail.object.key"),
              },
            ],
          }),
        }),
      ],
    });

    // Make identifiers used by runbook in put-secret-value / s3 cp copyable in deploy output.
    new CfnOutput(this, "TriageBucketName", {
      value: triageBucket.bucketName,
      description: "S3 bucket for triage (s3://<this>/triage/<uuid>.json)",
    });
    if (anthropicKeySecret) {
      new CfnOutput(this, "AnthropicApiKeySecretArn", {
        value: anthropicKeySecret.secretArn,
        description: "Secret ARN for loading ANTHROPIC_API_KEY with put-secret-value",
      });
    }
    new CfnOutput(this, "FixerGithubTokenSecretArn", {
      value: githubTokenSecret.secretArn,
      description: "Secret ARN for loading GitHub token with put-secret-value",
    });
  }
}
