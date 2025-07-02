def lambda_handler(event, context):
    order_id = (event.get('sessionState', {})
                       .get('intent', {})
                       .get('slots', {})
                       .get('orderID', {})
                       .get('value', {})
                       .get('interpretedValue', 'unknown'))
    return {
        "sessionState": {
            "dialogAction": { "type": "Close" },
            "intent": { "name": event['sessionState']['intent']['name'],
                        "state": "Fulfilled" }
        },
        "messages": [{
            "contentType": "PlainText",
            "content": f"Order #{order_id} is confirmed and will arrive tomorrow."
        }]
    }
