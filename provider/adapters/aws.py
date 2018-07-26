import random

try:
    import simplejson as json
except ImportError:
    import json

import boto3
from botocore.exceptions import NoCredentialsError, PartialCredentialsError
from botocore.exceptions import NoRegionError, ClientError


def init(ctx):
    try:
        ctx.debug('initializing AWS clients')

        ctx.ec2 = boto3.resource('ec2')
        ctx.trace(ctx.ec2)

        ctx.iam = boto3.resource('iam')
        ctx.trace(ctx.iam)

        # have to actually perform a lookup to make the lib
        # connect and verify the credentials are correct
        temp = list(ctx.iam.roles.all())

        ctx.vpc = {}
        ctx.blocks = {
            'env': {},
            'zone': {},
        }

        ctx.debug('AWS clients initialized')
        return

    except NoCredentialsError:
        ctx.error('Your AWS credentials couldn\'t be found. Use `aws '
                  'configure` to generate a credentials file, or set the '
                  '`AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` environment '
                  'variables and try again')

    except PartialCredentialsError:
        ctx.error('Your AWS credentials are incomplete. Use `aws configure` to '
                  '(re)generate a credentials file, or verify the '
                  '`AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` environment '
                  'variables are both set, and try again')

    except ClientError as err:
        if 'SignatureDoesNotMatch' in str(err):
            ctx.error('Your AWS credentials are incorrect. Use `aws configure` '
                      'to (re)generate your credentials file, or verify the '
                      '`AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` '
                      'environment variables are both correct, and try again')
        else:
            ctx.error(err)

    except NoRegionError:
        ctx.error('No AWS region set. Use `aws configure` to set a default, or '
                  'set the `AWS_DEFAULT_REGION` environment variable and try '
                  'again')

    exit(1)


def environment_setup(ctx, env, info):
    ctx.info('setting up %s env on AWS' % (env))

    found = list(ctx.ec2.vpcs.filter(Filters=[{
        'Name': 'tag:Name',
        'Values': ['nanobox-%s' % env],
    }]))
    ctx.trace('found: %s' % found)

    if len(found) < 1:
        ctx.debug('creating VPC')

        block = random.randint(0, 255)
        ctx.blocks['env'][env] = block

        ctx.vpc[env] = ctx.ec2.create_vpc(
            CidrBlock='10.%d.0.0/16' % block
        )
        ctx.vpc[env].wait_until_available()
        ctx.vpc[env].create_tags(Tags=[{
            'Key': 'Name',
            'Value': 'nanobox-%s' % env,
        },
            {
            'Key': 'Nanobox',
            'Value': 'true',
        }])
        ctx.trace('created VPC: %s' % ctx.vpc[env])

    else:
        ctx.debug('VPC already exists')

        ctx.vpc[env] = found[0]
        ctx.blocks['env'][env] = int(ctx.vpc[env].cidr_block.split('.')[1])
        ctx.trace('using VPC: %s' % ctx.vpc[env])

    ctx.blocks['zone'][env] = []

    if len(list(ctx.vpc[env].internet_gateways.all())) < 1:
        ctx.debug('creating Internet gateway')

        gw = ctx.ec2.create_internet_gateway()
        gw.create_tags(Tags=[{
            'Key': 'Name',
            'Value': 'nanobox-%s GW' % env,
        },
            {
            'Key': 'Nanobox',
            'Value': 'true',
        }])
        gw.attach_to_vpc(VpcId=ctx.vpc[env].vpc_id)
        ctx.trace('created Internet gateway: %s' % gw)

    else:
        ctx.debug('Internet gateway already attached')


def environment_security(ctx, env):
    ctx.debug('setting up %s security on AWS' % (env))

    subnets = list(ctx.ec2.subnets.filter(Filters=[{
        'Name': 'tag:Name',
        'Values': ['nanobox-%s subnet' % env],
    }]))
    ctx.trace('found: %s' % subnets)

    if len(subnets) < 1:
        ctx.debug('creating subnet')

        subnet = ctx.vpc[env].create_subnet(
            CidrBlock=ctx.vpc[env].cidr_block,
        )
        subnet.create_tags(Tags=[{
            'Key': 'Name',
            'Value': 'nanobox-%s subnet' % env,
        },
            {
            'Key': 'Nanobox',
            'Value': 'true',
        }])
        ctx.trace('created subnet: %s' % subnet)

    else:
        ctx.debug('subnet already exists')

        subnet = subnets[0]
        ctx.trace('using subnet: %s' % subnet)

    boto3.client('ec2').modify_subnet_attribute(
        MapPublicIpOnLaunch={
            'Value': True,
        },
        SubnetId=subnet.subnet_id,
    )


def environment_acls(ctx, env, info):
    ctx.debug('setting up %s ACLs on AWS' % env)

    if 'use_zones' in info and info['use_zones']:
        zone = info.get('application_zone', '')

        subnet = list(ctx.ec2.subnets.filter(Filters=[{
            'Name': 'tag:Name',
            'Values': ['nanobox-%s-%s subnet' % (env, zone)],
        }]))[0]
        secgrp = list(ctx.vpc[env].security_groups.filter(Filters=[{
            'Name': 'group-name',
            'Values': ['nanobox-%s-%s secgrp' % (env, zone)],
        }]))[0]
    else:
        subnet = list(ctx.ec2.subnets.filter(Filters=[{
            'Name': 'tag:Name',
            'Values': ['nanobox-%s subnet' % env],
        }]))[0]
        secgrp = list(ctx.vpc[env].security_groups.filter(Filters=[{
            'Name': 'group-name',
            'Values': ['default'],
        }]))[0]

    user = ctx.iam.User('nanobox-%s' % env)
    try:
        user.load()
        ctx.trace('using user: %s' % user)
    except ClientError:
        user.create()
        ctx.trace('created user: %s' % user)

    for key in list(user.access_keys.all()):
        key.delete()
    key = user.create_access_key_pair()
    ctx.trace('created keypair: %s' % (key))

    policy = user.Policy('NanoboxDeployment-%s' % env)
    try:
        policy.load()
        ctx.trace('using policy: %s' % policy)
    except ClientError:
        policy.put(
            PolicyDocument=json.dumps({
                'Version': '2012-10-17',
                'Statement': [{
                    'Effect': 'Allow',
                    'Action': [
                        'ec2:CreateTags',
                        'ec2:RebootInstances',
                        'ec2:RunInstances',
                        'ec2:TerminateInstances',
                    ],
                    'Resource': [
                        'arn:aws:ec2:*::image/*',
                        'arn:aws:ec2:*:*:instance/*',
                        'arn:aws:ec2:*:*:network-interface/*',
                        'arn:aws:ec2:*:*:security-group/%s' % secgrp.id,
                        'arn:aws:ec2:*:*:subnet/%s' % subnet.id,
                        'arn:aws:ec2:*:*:volume/*',
                    ],
                },
                {
                    'Effect': 'Allow',
                    'Action': [
                        'ec2:DescribeAvailabilityZones',
                        'ec2:DescribeInstances',
                        'ec2:DescribeKeyPairs',
                        'ec2:DescribeSecurityGroups',
                        'ec2:DescribeSubnets',
                        'ec2:DescribeVpcs',
                        'ec2:ImportKeyPair',
                        'ec2:DeleteKeyPair',
                    ],
                    'Resource': '*',
                }]
            })
        )
        ctx.trace('created policy: %s' % policy)

    return {
        'key_id': key.id,
        'secret': key.secret,
    }


def environment_controller(ctx, env):
    ctx.debug('creating %s controller on AWS' % env)

    # TODO


def zone_setup(ctx, env, zone, info):
    ctx.debug('setting up %s zone in %s env on AWS' % (zone, env))

    subnets = list(ctx.ec2.subnets.filter(Filters=[{
        'Name': 'tag:Name',
        'Values': ['nanobox-%s-%s subnet' % (env, zone)],
    }]))
    ctx.trace('found: %s' % subnets)

    if len(subnets) < 1:
        ctx.debug('creating subnet')

        block = random.randint(0, 255)
        while block in ctx.blocks['zone'][env]:
            block = random.randint(0, 255)
        ctx.blocks['zone'][env].append(block)

        subnet = ctx.vpc[env].create_subnet(
            CidrBlock='10.%d.%d.0/24' % (ctx.blocks['env'][env], block)
        )
        subnet.create_tags(Tags=[{
            'Key': 'Name',
            'Value': 'nanobox-%s-%s subnet' % (env, zone),
        },
            {
            'Key': 'Nanobox',
            'Value': 'true',
        }])
        ctx.trace('created subnet: %s' % subnet)

    else:
        ctx.debug('subnet already exists')

        subnet = subnets[0]
        ctx.blocks['zone'][env].append(int(subnet.cidr_block.split('.')[2]))
        ctx.trace('using subnet: %s' % subnet)

    if 'networking' in info \
            and 'in' in info['networking'] \
            and 'pub' in info['networking']['in']:
        boto3.client('ec2').modify_subnet_attribute(
            MapPublicIpOnLaunch={
                'Value': True,
            },
            SubnetId=subnet.subnet_id,
        )


def zone_security(ctx, env, zone, info):
    ctx.debug('setting up %s security in %s env on AWS using %s' %
              (zone, env, json.dumps(info['networking']
                                     if 'networking' in info else {})))

    nets = {
        'in': {
            target: (list(ctx.ec2.subnets.filter(Filters=[{
                'Name': 'tag:Name',
                'Values': ['nanobox-%s-%s subnet' % (env, target)],
            }]))[0].cidr_block if target != 'pub' else '0.0.0.0/0')
            for target in info['networking']['in']
        } if 'in' in info['networking'] else {},
        'out': {
            target: (list(ctx.ec2.subnets.filter(Filters=[{
                'Name': 'tag:Name',
                'Values': ['nanobox-%s-%s subnet' % (env, target)],
            }]))[0].cidr_block if target != 'pub' else '0.0.0.0/0')
            for target in info['networking']['out']
        } if 'out' in info['networking'] else {},
    } if 'networking' in info else {'in': {}, 'out': {}}
    ctx.trace('nets: %s' % nets)

    found = list(ctx.vpc[env].security_groups.filter(Filters=[{
        'Name': 'group-name',
        'Values': ['nanobox-%s-%s secgrp' % (env, zone)],
    }]))
    ctx.trace('found: %s' % found)

    if len(found) < 1:
        ctx.debug('creating security group')

        sgrp = ctx.vpc[env].create_security_group(
            Description='%s security group for the %s zone' % (env, zone),
            GroupName='nanobox-%s-%s secgrp' % (env, zone),
        )
        ctx.trace('created security group: %s' % sgrp)

    else:
        sgrp = found[0]
        ctx.trace('using security group: %s' % sgrp)

    ctx.trace('ingress rules (before): %s' % sgrp.ip_permissions)
    ctx.trace('egress rules (before): %s' % sgrp.ip_permissions_egress)

    try:
        sgrp.revoke_egress(
            IpPermissions=[
                {
                    'IpProtocol': '-1',
                    'IpRanges': [
                        {
                            'CidrIp': '0.0.0.0/0'
                        },
                    ],
                },
            ],
        )
    except ClientError:
        pass

    try:
        sgrp.authorize_ingress(IpPermissions=[{
            'IpProtocol': '-1',
            'UserIdGroupPairs': [
                {
                    'GroupId': sgrp.group_id,
                    'Description': 'chatter within %s' % zone,
                },
            ],
        }])
    except ClientError:
        pass

    ingress = []
    if len(sgrp.ip_permissions) > 0:
        for perm in sgrp.ip_permissions:
            if perm['IpProtocol'] == '-1':
                ingress = perm['IpRanges']
                break

    egress = []
    if len(sgrp.ip_permissions_egress) > 0:
        for perm in sgrp.ip_permissions_egress:
            if perm['IpProtocol'] == '-1':
                egress = perm['IpRanges']
                break

    for target in nets['in']:
        range = {
            'CidrIp': nets['in'][target],
            'Description': 'ingress from %s to %s' % (target, zone),
        }

        if range not in ingress:
            sgrp.authorize_ingress(IpPermissions=[{
                'IpProtocol': '-1',
                'IpRanges': [range],
            }])

    for target in nets['out']:
        range = {
            'CidrIp': nets['out'][target],
            'Description': 'egress to %s from %s' % (target, zone),
        }

        if range not in egress:
            sgrp.authorize_egress(IpPermissions=[{
                'IpProtocol': '-1',
                'IpRanges': [range],
            }])

    ctx.trace('ingress rules (after): %s' % sgrp.ip_permissions)
    ctx.trace('egress rules (after): %s' % sgrp.ip_permissions_egress)


def zone_controller(ctx, env, zone):
    ctx.debug('creating %s controller in %s zone on AWS' % (env, zone))

    # TODO


def zone_components(ctx, env, zone, info):
    if 'components' not in info or len(info['components']) < 1:
        return

    ctx.debug('creating %s components in %s env on AWS using %s' %
              (zone, env, json.dumps(info['components'])))

    # TODO


def zone_lockdown(ctx, env, zone, info):
    if 'components' not in info or len(info['components']) < 1:
        return

    ctx.debug('locking down %s components in %s env on AWS using %s' %
              (zone, env, json.dumps(info['components'])))

    # Switch installed components to use the security group for their Zone
    # TODO
