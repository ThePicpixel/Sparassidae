from utils import *
from time import sleep

def setup(conf):

    for cots in conf.keys():

        if conf[cots]["enabled"] and "config" in conf[cots].keys():

            print(f"[*] Setting up {cots}")

            if not os.path.exists(cots):
                os.makedirs(f"{cots}/conf", exist_ok=True)
                

            with open(cots + "/conf/" + conf[cots]["config"]["filename"], "w") as f:
                f.write(render_config(f"templates/{cots}/conf.template", conf))

            if os.path.exists(f"./build/{cots}"):

                print(f"[*] Building {cots}")

                cmd = f"podman build ./build/{cots} -t {cots}-sparassidae:latest"
                os.system(cmd)


def run(conf):

    url = "unix:///run/user/1000/podman/podman.sock"
    
    print("[*] Creating pod")
    deploy_pod(url, conf["pod"])

    print("[*] Creating ES certs")
    create_es_certificates(url)

    while not os.path.exists("./elasticsearch/cert/elastic-certificates.p12"):
        sleep(1)

    os.system("chmod g+r elasticsearch/cert/*")

    print("[*] Deploying elasticsearch")
    deploy_container(url, conf["containers"]["elasticsearch"], "sparassidae.elasticsearch")

    print("[*] Waiting for elasticsearch to be up...")
    cmd = f'curl http://{conf["containers"]["elasticsearch"]["host"]}:{conf["containers"]["elasticsearch"]["port"]}'
    output, error = execute(cmd)

    while "curl" in output.decode():
        output, error = execute(cmd)
        sleep(1)

    for cots in conf["containers"].keys():
        if cots != "elasticsearch" and conf["containers"][cots]["enabled"]:
            print(f'[*] Deploying {cots}')
            deploy_container(url, conf["containers"][cots], f'sparassidae.{cots}')


    print("[*] Changing kibana password")
    es_pass = ""
    for env in conf["containers"]["elasticsearch"]["env"]:
        if env["name"] == "ELASTIC_PASSWORD":
            es_pass = env["value"]
            break

    os.system(f'curl -XPOST -u elastic:{es_pass} http://{conf["containers"]["elasticsearch"]["host"]}:{conf["containers"]["elasticsearch"]["port"]}/_security/user/{conf["containers"]["kibana"]["user"]}/_password -H "Content-Type: application/json" -d \'{{"password":"{conf["containers"]["kibana"]["pass"]}"}}\'')

    print("[*] Changing logstash password")
    os.system(f'curl -XPOST -u elastic:{es_pass} http://{conf["containers"]["elasticsearch"]["host"]}:{conf["containers"]["elasticsearch"]["port"]}/_security/user/{conf["containers"]["logstash"]["user"]}/_password -H "Content-Type: application/json" -d \'{{"password":"{conf["containers"]["logstash"]["pass"]}"}}\'')

if __name__ == '__main__':

    print("[*] Loading params")
    conf = load_conf("values.yaml")
    
    print("[*] Starting setup")
    setup(conf["containers"])

    print("[*] Starting containers")
    run(conf)
