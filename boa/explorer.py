import json

import requests

from boa.environment import Address

SESSION = requests.Session()


def fetch_abi_from_etherscan(
    address: str, uri: str = "https://api.etherscan.io/api", api_key: str = None
):
    address = Address(address)

    params = dict(module="contract", action="getabi", address=address)
    if api_key is not None:
        params["apikey"] = api_key

    res = SESSION.get(uri, params=params)
    res.raise_for_status()

    data = res.json()

    if int(data["status"]) != 1:
        raise ValueError(f"Failed to retrieve data from API: {data}")

    return json.loads(data["result"].strip())
