# SPARASSIDAE

Sparassidae is my own implementation of a Detection Platform. **It is not meant to be used in production**.

## Prerequisites

The environment is completely containerized and I am using pod concept to deploy everything.

Therefore, you need to install **podman**.

## Usage

You can edit the **values.yaml** to configure your own parameters.

Then, create a virtualenv, install dependencies and activate the virtualenv :

```bash
virtualenv env
pip install -r requirements.txt
source ./env/bin/activate
```

Finally, run the following :

```bash
python3 main.py
```

NOTE : Kibana server may take a few time to be up and running, just wait a little bit
