import { Duration, Stack, Tags, type StackProps } from 'aws-cdk-lib';
import {
  OpenIdConnectProvider,
  Policy,
  PolicyDocument,
  PolicyStatement,
  Role,
  User,
  WebIdentityPrincipal
} from 'aws-cdk-lib/aws-iam';
import { BlockPublicAccess, Bucket, BucketEncryption, HttpMethods } from 'aws-cdk-lib/aws-s3';
import { StringParameter } from 'aws-cdk-lib/aws-ssm';
import type { Construct, Node } from 'constructs';

export interface DciTailorSettings {
  readonly account: string;
  readonly region: string;
  readonly domain: string;
  readonly stagingDomain: string;
  readonly repository: string;
  readonly hostAppTagValue: string;
}

export const DCI_TAILOR_DEFAULTS: DciTailorSettings = {
  account: '724654236968',
  region: 'us-west-2',
  domain: 'dci-tailor.glazecalcapp.com',
  stagingDomain: 'dci-tailor-staging.glazecalcapp.com',
  repository: 'AaronFilson/detective-ceramic-ingredient-tailor',
  hostAppTagValue: 'glazecalc'
};

const PATTERNS: Record<keyof DciTailorSettings, RegExp> = {
  account: /^\d{12}$/,
  region: /^[a-z]{2}(-[a-z]+)+-\d$/,
  domain: /^([a-z0-9-]+\.)+[a-z]{2,}$/,
  stagingDomain: /^([a-z0-9-]+\.)+[a-z]{2,}$/,
  repository: /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/,
  hostAppTagValue: /^[A-Za-z0-9_.-]+$/
};

export function readDciTailorSettings(node: Node): DciTailorSettings {
  const read = <K extends keyof DciTailorSettings>(key: K): string => {
    const given: unknown = node.tryGetContext(key);
    const value = given === undefined ? DCI_TAILOR_DEFAULTS[key] : String(given);
    const pattern = PATTERNS[key];
    if (!pattern.test(value)) {
      throw new Error(`Context ${key} must match ${pattern}, got ${JSON.stringify(given)}.`);
    }
    return value;
  };

  return {
    account: read('account'),
    region: read('region'),
    domain: read('domain'),
    stagingDomain: read('stagingDomain'),
    repository: read('repository'),
    hostAppTagValue: read('hostAppTagValue')
  };
}

export interface DciTailorStackProps extends StackProps {
  readonly settings?: DciTailorSettings;
}

const GITHUB_ISSUER = 'token.actions.githubusercontent.com';
const STS_AUDIENCE = 'sts.amazonaws.com';

export class DciTailorStack extends Stack {
  readonly storageBucket: Bucket;
  readonly storageUser: User;
  readonly bucketParameter: StringParameter;
  readonly deployRole: Role;

  constructor(scope: Construct, id: string, props: DciTailorStackProps = {}) {
    super(scope, id, props);

    const settings = props.settings ?? readDciTailorSettings(this.node);
    const { account, region, domain, stagingDomain, repository, hostAppTagValue } = settings;

    // 1. Private encrypted S3 bucket for ActiveStorage photos/variants and nightly PostGIS dumps.
    this.storageBucket = new Bucket(this, 'StorageBucket', {
      bucketName: `dci-tailor-storage-${account}`,
      blockPublicAccess: BlockPublicAccess.BLOCK_ALL,
      encryption: BucketEncryption.S3_MANAGED,
      enforceSSL: true,
      cors: [
        {
          allowedMethods: [HttpMethods.GET, HttpMethods.HEAD, HttpMethods.PUT, HttpMethods.POST],
          allowedOrigins: [`https://${domain}`, `https://${stagingDomain}`],
          allowedHeaders: ['*'],
          exposedHeaders: ['ETag'],
          maxAge: 3600
        }
      ],
      lifecycleRules: [
        {
          id: 'expire-staging-uploads',
          prefix: 'staging/',
          expiration: Duration.days(14)
        },
        {
          id: 'expire-pgdumps',
          prefix: 'pgdump/',
          expiration: Duration.days(30)
        },
        {
          id: 'abort-incomplete-multipart',
          abortIncompleteMultipartUploadAfter: Duration.days(2)
        }
      ]
    });

    // 2. Least-privilege IAM user for container ActiveStorage & backup uploads (IMDSv2 hop-limit = 1).
    this.storageUser = new User(this, 'StorageUser', {
      userName: 'dci-tailor-storage'
    });
    this.storageUser.attachInlinePolicy(
      new PolicyStatementToInlinePolicy(this, 'StorageUserPolicy', 'dci-tailor-s3-storage', [
        new PolicyStatement({
          sid: 'ReadWriteDeleteStorageObjects',
          actions: ['s3:GetObject', 's3:PutObject', 's3:DeleteObject'],
          resources: [this.storageBucket.arnForObjects('*')]
        }),
        new PolicyStatement({
          sid: 'ListStorageBucket',
          actions: ['s3:ListBucket'],
          resources: [this.storageBucket.bucketArn]
        })
      ]).policy
    );

    // 3. SSM Parameter Store entry naming the storage/backup bucket for host backup scripts & Kamal.
    this.bucketParameter = new StringParameter(this, 'StorageBucketParameter', {
      parameterName: '/dci-tailor/storage-bucket',
      stringValue: this.storageBucket.bucketName
    });

    // 4. GitHub Actions OIDC deploy role referencing the account's existing GitHub OIDC provider
    //    (created by glazecalc-access) so `cdk deploy` coexists cleanly in account 724654236968.
    const githubOidc = OpenIdConnectProvider.fromOpenIdConnectProviderArn(
      this,
      'GitHubOidcProvider',
      `arn:aws:iam::${account}:oidc-provider/${GITHUB_ISSUER}`
    );

    this.deployRole = new Role(this, 'DeployRole', {
      roleName: 'dci-tailor-deploy',
      assumedBy: new WebIdentityPrincipal(githubOidc.openIdConnectProviderArn, {
        StringEquals: {
          [`${GITHUB_ISSUER}:aud`]: STS_AUDIENCE
        },
        StringLike: {
          [`${GITHUB_ISSUER}:sub`]: `repo:${repository}:*`
        }
      }),
      inlinePolicies: {
        'dci-tailor-ssm-deploy': new PolicyDocument({
          statements: [
            new PolicyStatement({
              sid: 'SessionAndRunCommandOnHostInstance',
              actions: ['ssm:StartSession', 'ssm:SendCommand'],
              resources: [`arn:aws:ec2:${region}:${account}:instance/*`],
              conditions: {
                StringEquals: {
                  'ssm:resourceTag/app': hostAppTagValue
                }
              }
            }),
            new PolicyStatement({
              sid: 'AllowSsmSshAndShellDocuments',
              actions: ['ssm:StartSession', 'ssm:SendCommand'],
              resources: [
                `arn:aws:ssm:${region}::document/AWS-StartSSHSession`,
                `arn:aws:ssm:${region}::document/AWS-RunShellScript`
              ]
            }),
            new PolicyStatement({
              sid: 'ManageSsmSessions',
              actions: ['ssm:TerminateSession', 'ssm:ResumeSession'],
              resources: [`arn:aws:ssm:${region}:${account}:session/*`]
            }),
            new PolicyStatement({
              sid: 'DescribeHostInstancesAndCommandResults',
              actions: [
                'ec2:DescribeInstances',
                'ssm:DescribeInstanceInformation',
                'ssm:GetCommandInvocation',
                'ssm:ListCommandInvocations',
                'ssm:ListCommands'
              ],
              resources: ['*']
            }),
            new PolicyStatement({
              sid: 'ReadDciTailorSsmSecrets',
              actions: ['ssm:GetParameter', 'ssm:GetParameters', 'ssm:GetParametersByPath'],
              resources: [
                `arn:aws:ssm:${region}:${account}:parameter/dci-tailor`,
                `arn:aws:ssm:${region}:${account}:parameter/dci-tailor/*`
              ]
            })
          ]
        })
      }
    });

    Tags.of(this).add('service', 'dci-tailor');
  }
}

class PolicyStatementToInlinePolicy {
  readonly policy: Policy;

  constructor(scope: Construct, id: string, policyName: string, statements: PolicyStatement[]) {
    this.policy = new Policy(scope, id, {
      policyName,
      statements
    });
  }
}
