FROM elasticsearch:8.0.1

COPY entrypoint.sh /bin/

USER root
RUN chmod +x /bin/entrypoint.sh

ENTRYPOINT ["/bin/entrypoint.sh"]