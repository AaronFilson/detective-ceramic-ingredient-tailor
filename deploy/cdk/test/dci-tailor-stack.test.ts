import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { describe, it } from 'node:test';
import { Match, Template } from 'aws-cdk-lib/assertions';
import { buildDciTailorApp } from '../bin/app.ts';

const CDK_JSON_CONTEXT = (
  JSON.parse(readFileSync(new URL('../cdk.json', import.meta.url), 'utf8')) as { context: Record<string, unknown> }
).context;

function synthTemplate(overrides: Record<string, unknown> = {}): Template {
  const { stack } = buildDciTailorApp({
    ...CDK_JSON_CONTEXT,
    ...overrides
  });
  return Template.fromStack(stack);
}

describe('DciTailorStack', () => {
  it('creates isolated production and staging AES256-encrypted S3 buckets with TLS enforcement, CORS, and lifecycle rules', () => {
    const template = synthTemplate();

    template.hasResourceProperties('AWS::S3::Bucket', {
      BucketName: 'dci-tailor-storage-724654236968',
      PublicAccessBlockConfiguration: {
        BlockPublicAcls: true,
        BlockPublicPolicy: true,
        IgnorePublicAcls: true,
        RestrictPublicBuckets: true
      },
      BucketEncryption: {
        ServerSideEncryptionConfiguration: [
          {
            ServerSideEncryptionByDefault: {
              SSEAlgorithm: 'AES256'
            }
          }
        ]
      },
      CorsConfiguration: {
        CorsRules: [
          {
            AllowedHeaders: ['*'],
            AllowedMethods: ['GET', 'HEAD', 'PUT', 'POST'],
            AllowedOrigins: ['https://dci-tailor.glazecalcapp.com'],
            ExposedHeaders: ['ETag'],
            MaxAge: 3600
          }
        ]
      },
      LifecycleConfiguration: {
        Rules: Match.arrayWith([
          Match.objectLike({
            Id: 'expire-pgdumps',
            Prefix: 'pgdump/',
            ExpirationInDays: 30,
            Status: 'Enabled'
          })
        ])
      }
    });

    template.hasResourceProperties('AWS::S3::Bucket', {
      BucketName: 'dci-tailor-staging-storage-724654236968',
      PublicAccessBlockConfiguration: {
        BlockPublicAcls: true,
        BlockPublicPolicy: true,
        IgnorePublicAcls: true,
        RestrictPublicBuckets: true
      },
      BucketEncryption: {
        ServerSideEncryptionConfiguration: [
          {
            ServerSideEncryptionByDefault: {
              SSEAlgorithm: 'AES256'
            }
          }
        ]
      },
      CorsConfiguration: {
        CorsRules: [
          {
            AllowedHeaders: ['*'],
            AllowedMethods: ['GET', 'HEAD', 'PUT', 'POST'],
            AllowedOrigins: ['https://dci-tailor-staging.glazecalcapp.com'],
            ExposedHeaders: ['ETag'],
            MaxAge: 3600
          }
        ]
      },
      LifecycleConfiguration: {
        Rules: Match.arrayWith([
          Match.objectLike({
            Id: 'expire-staging-objects',
            Prefix: Match.absent(),
            ExpirationInDays: 14,
            Status: 'Enabled'
          })
        ])
      }
    });

    template.resourceCountIs('AWS::S3::BucketPolicy', 2);
    template.hasResourceProperties('AWS::S3::BucketPolicy', {
      PolicyDocument: {
        Statement: Match.arrayWith([
          Match.objectLike({
            Effect: 'Deny',
            Action: 's3:*',
            Condition: {
              Bool: {
                'aws:SecureTransport': 'false'
              }
            }
          })
        ])
      }
    });
  });

  it('creates isolated IAM storage users and explicitly denies pgdump/* access to dci-tailor-storage', () => {
    const template = synthTemplate();

    template.hasResourceProperties('AWS::IAM::User', {
      UserName: 'dci-tailor-storage'
    });
    template.hasResourceProperties('AWS::IAM::User', {
      UserName: 'dci-tailor-staging-storage'
    });

    template.hasResourceProperties('AWS::IAM::Policy', {
      PolicyName: 'dci-tailor-s3-storage',
      PolicyDocument: {
        Statement: [
          {
            Sid: 'ReadWriteDeleteStorageObjects',
            Effect: 'Allow',
            Action: ['s3:GetObject', 's3:PutObject', 's3:DeleteObject'],
            Resource: {
              'Fn::Join': ['', [{ 'Fn::GetAtt': [Match.stringLikeRegexp('^StorageBucket'), 'Arn'] }, '/*']]
            }
          },
          {
            Sid: 'ListStorageBucket',
            Effect: 'Allow',
            Action: 's3:ListBucket',
            Resource: { 'Fn::GetAtt': [Match.stringLikeRegexp('^StorageBucket'), 'Arn'] }
          },
          {
            Sid: 'DenyPgdumpBackupAccess',
            Effect: 'Deny',
            Action: 's3:*',
            Resource: {
              'Fn::Join': ['', [{ 'Fn::GetAtt': [Match.stringLikeRegexp('^StorageBucket'), 'Arn'] }, '/pgdump/*']]
            }
          }
        ]
      }
    });

    template.hasResourceProperties('AWS::IAM::Policy', {
      PolicyName: 'dci-tailor-staging-s3-storage',
      PolicyDocument: {
        Statement: [
          {
            Sid: 'ReadWriteDeleteStagingStorageObjects',
            Effect: 'Allow',
            Action: ['s3:GetObject', 's3:PutObject', 's3:DeleteObject'],
            Resource: {
              'Fn::Join': ['', [{ 'Fn::GetAtt': [Match.stringLikeRegexp('^StagingStorageBucket'), 'Arn'] }, '/*']]
            }
          },
          {
            Sid: 'ListStagingStorageBucket',
            Effect: 'Allow',
            Action: 's3:ListBucket',
            Resource: { 'Fn::GetAtt': [Match.stringLikeRegexp('^StagingStorageBucket'), 'Arn'] }
          }
        ]
      }
    });
  });

  it('publishes both production and staging storage bucket names in SSM Parameter Store', () => {
    const template = synthTemplate();

    template.hasResourceProperties('AWS::SSM::Parameter', {
      Name: '/dci-tailor/storage-bucket',
      Type: 'String'
    });
    template.hasResourceProperties('AWS::SSM::Parameter', {
      Name: '/dci-tailor/staging/storage-bucket',
      Type: 'String'
    });
  });

  it('locks GitHub Actions OIDC role dci-tailor-deploy strictly to production/staging environments and SSH-only SSM sessions', () => {
    const template = synthTemplate();

    template.hasResourceProperties('AWS::IAM::Role', {
      RoleName: 'dci-tailor-deploy',
      AssumeRolePolicyDocument: {
        Statement: [
          {
            Effect: 'Allow',
            Action: 'sts:AssumeRoleWithWebIdentity',
            Principal: {
              Federated: 'arn:aws:iam::724654236968:oidc-provider/token.actions.githubusercontent.com'
            },
            Condition: {
              StringEquals: {
                'token.actions.githubusercontent.com:aud': 'sts.amazonaws.com',
                'token.actions.githubusercontent.com:sub': [
                  'repo:AaronFilson/detective-ceramic-ingredient-tailor:environment:production',
                  'repo:AaronFilson/detective-ceramic-ingredient-tailor:environment:staging'
                ]
              },
              StringLike: Match.absent()
            }
          }
        ]
      },
      Policies: [
        {
          PolicyName: 'dci-tailor-ssm-deploy',
          PolicyDocument: {
            Statement: [
              {
                Sid: 'StartSsmSessionOnHostInstance',
                Effect: 'Allow',
                Action: 'ssm:StartSession',
                Resource: 'arn:aws:ec2:us-west-2:724654236968:instance/*',
                Condition: {
                  StringEquals: {
                    'ssm:resourceTag/app': 'glazecalc'
                  }
                }
              },
              {
                Sid: 'AllowSsmSshDocument',
                Effect: 'Allow',
                Action: 'ssm:StartSession',
                Resource: 'arn:aws:ssm:us-west-2::document/AWS-StartSSHSession'
              },
              {
                Sid: 'ManageOwnSsmSessions',
                Effect: 'Allow',
                Action: ['ssm:TerminateSession', 'ssm:ResumeSession'],
                Resource: 'arn:aws:ssm:us-west-2:724654236968:session/${aws:userid}-*'
              },
              {
                Sid: 'DescribeHostInstances',
                Effect: 'Allow',
                Action: ['ec2:DescribeInstances', 'ssm:DescribeInstanceInformation'],
                Resource: '*'
              },
              {
                Sid: 'ReadDciTailorSsmSecrets',
                Effect: 'Allow',
                Action: ['ssm:GetParameter', 'ssm:GetParameters', 'ssm:GetParametersByPath'],
                Resource: [
                  'arn:aws:ssm:us-west-2:724654236968:parameter/dci-tailor',
                  'arn:aws:ssm:us-west-2:724654236968:parameter/dci-tailor/*'
                ]
              }
            ]
          }
        }
      ]
    });

    const roleJson = JSON.stringify(template.findResources('AWS::IAM::Role'));
    for (const forbidden of [
      'ssm:SendCommand',
      'AWS-RunShellScript',
      'ssm:GetCommandInvocation',
      'ssm:ListCommandInvocations',
      'ssm:ListCommands'
    ]) {
      assert.equal(roleJson.includes(forbidden), false, `Deploy role must not include ${forbidden}`);
    }
  });

  it('rejects malformed AWS account context settings at synth time', () => {
    assert.throws(() => synthTemplate({ account: 'not-an-account' }), /Context account must match/);
  });
});
