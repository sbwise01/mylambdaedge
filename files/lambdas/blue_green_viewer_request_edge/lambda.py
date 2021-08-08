def lambda_handler(event, context):
    request = event['Records'][0]['cf']['request']
    headers = request['headers']

    hostName = headers.get('host')[0]['value']
    subDomain = hostName.split('.')[0]
    print("Adding blue green header for host %s" % hostName)
    if subDomain.endswith('-test'):
        request['headers']['x-blue-green-context'] = [{'key': 'x-blue-green-context', 'value': "green"}]
    else:
        request['headers']['x-blue-green-context'] = [{'key': 'x-blue-green-context', 'value': "blue"}]

    return request
