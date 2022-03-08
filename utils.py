from jinja2 import Template
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


def deploy_pod():
    cmd = "podman pod create --name sparassidae --publish 5601:5601 --publish 9200:9200 --publish 5140:5140"
    execute(cmd)

def create_es_certificates():

    if not os.path.exists("elasticsearch/cert/elastic-certificates.p12"):
        os.makedirs("elasticsearch/cert", exist_ok=True)

        cmd = "podman run -it --rm -v $(pwd)/elasticsearch/cert:/shared/cert elasticsearch /bin/bash"
        os.system(cmd)
        os.system("chmod 644 ./elasticsearch/cert/elastic-certificates.p12")


def deploy_container(conf, cots):
    
    cmd = f"podman run --pod sparassidae --name sparassidae.{cots} -d "

    if "env" in conf[cots].keys():
        for env in conf[cots]["env"]:
            cmd += f'-e "{env["name"]}={env["value"]}" '

    if "volumes" in conf[cots].keys():
        for vol in conf[cots]["volumes"]:
            
            if not os.path.exists(vol["path"]):
                os.makedirs(vol["path"], exist_ok=True)

            if vol["path"].startswith('/'):
                cmd += f'-v {vol["path"]}:{vol["mountPath"]} '
            else:
                cmd += f'-v $(pwd)/{vol["path"]}:{vol["mountPath"]} '

    cmd += f'{conf[cots]["container"]["image"]}:{conf[cots]["container"]["tag"]} '

    if "command_line" in conf[cots].keys():
        cmd += conf[cots]["command_line"]

    os.system(cmd)

