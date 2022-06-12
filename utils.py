from jinja2 import Template
from podman import PodmanClient
import shlex, subprocess
import yaml
import os


def render_config(filename, conf):

    with open(filename, "r") as f:

        tmp = Template(f.read())

    return tmp.render(conf=conf)


def load_conf(filename):

    with open("values.yaml", "r") as stream:

        conf = yaml.safe_load(stream)

    return conf


def execute(cmd):

    cmd = shlex.split(cmd)
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

    return proc.communicate()


def deploy_pod(socket, conf):

    portmappings = [
            {
                "container_port": port,
                "host_ip": "0.0.0.0",
                "host_port": port,
                "protocol": "tcp"
            } for port in conf["expose"]
        ]

    with PodmanClient(base_url=socket) as client:
        response = client.pods.create(conf["name"], portmappings=portmappings)

    return response

def create_es_certificates(url):

    if not os.path.exists("elasticsearch/cert/elastic-certificates.p12"):
        os.makedirs("elasticsearch/cert", exist_ok=True)

        params = {
            "container": {
                "image": "elasticsearch-sparassidae",
                "tag": "latest"
            },
            "volumes": [
                {
                    "path": os.path.abspath("elasticsearch/cert"),
                    "mountPath": "/shared/cert",
                    "mode": "rw"
                }
            ],            
            "auto_remove": True
        }

        deploy_container(url, params, 'elastic-certs')


def deploy_container(url, conf, name):

    image_name = f'{conf["container"]["image"]}:{conf["container"]["tag"]}'

    env = {var["name"]:var["value"] for var in conf["env"]} if "env" in conf.keys() else {}

    mounts = [
        {
            "target": vol["mountPath"],
            "source": os.path.abspath(vol["path"]),
            "type": "bind"
        } for vol in conf["volumes"]
    ] if "volumes" in conf.keys() else []
    
    if "volumes" in conf.keys():
        for vol in conf["volumes"]:
            if not os.path.exists(vol["path"]):
                os.makedirs(vol["path"], exist_ok=True)

    command = conf["command_line"].split(" ") if "command_line" in conf.keys() else []

    entrypoint = conf["entrypoint"] if "entrypoint" in conf.keys() else []

    auto_remove = conf["auto_remove"] if "auto_remove" in conf.keys() else False

    with PodmanClient(base_url=url) as client:
        image = client.images.get(image_name)
        response = client.containers.create(
            image,
            pod="sparassidae",
            name=name,
            environment=env,
            mounts=mounts,
            command=command,
            entrypoint=entrypoint,
            auto_remove=auto_remove
        )

        response.start()

    return response

