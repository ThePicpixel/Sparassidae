from utils import *


def setup(conf):

    for cots in conf.keys():

        if conf[cots]["enabled"]:

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
    
    print("[*] Creating pod")
    deploy_pod()

    print("[*] Creating ES certs")
    create_es_certificates()

    if conf["elasticsearch"]["enabled"]:
        print("[*] Deploying elasticsearch")
        deploy_container(conf, "elasticsearch")

    if conf["kibana"]["enabled"]:
        print("[*] Deploying kibana")
        deploy_container(conf, "kibana")

    if conf["fluentd"]["enabled"]:
        print("[*] Deploying fluentd")
        deploy_container(conf, "fluentd")

    print("[*] Waiting for elasticsearch to be up...")
    cmd = f'curl http://{conf["elasticsearch"]["host"]}:{conf["elasticsearch"]["port"]}'
    output, error = execute(cmd)

    while "curl" in output.decode():
        output, error = execute(cmd)

    print("[*] Configuring Kibana password")
    
    es_pass = ""
    for env in conf["elasticsearch"]["env"]:
        if env["name"] == "ELASTIC_PASSWORD":
            es_pass = env["value"]
            break

    os.system(f'curl -XPOST -u elastic:{es_pass} http://{conf["elasticsearch"]["host"]}:{conf["elasticsearch"]["port"]}/_security/user/{conf["kibana"]["user"]}/_password -H "Content-Type: application/json" -d \'{{"password":"{conf["kibana"]["pass"]}"}}\'')

    if conf["elastalert2"]["enabled"]:
        print("[*] Deploying elastalert2")
        deploy_container(conf, "elastalert2")


if __name__ == '__main__':

    print("[*] Loading params")
    conf = load_conf("values.yaml")
    
    print("[*] Starting setup")
    setup(conf)

    print("[*] Starting containers")
    run(conf)
