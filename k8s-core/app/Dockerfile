# myjavaapp – Tomcat + login.war, ready for the K8s building-blocks lab (and OpenShift).
#
#   wget https://maha02spet26.s3.us-east-2.amazonaws.com/login.war
#   docker build -t myjavaapp:3 .
#   docker run --name myc1 -d -p 8081:8080 -e APP_ENV=dev myjavaapp:3
#   curl http://localhost:8081/login/

# Tomcat 9 still uses javax.* like 8.5, so the old WAR runs unchanged.
# Tomcat 8.5 is end-of-life (no security fixes). If the app needs Java 8, use tomcat:9.0-jre8.
FROM tomcat:9.0-jre17

# MAINTAINER is deprecated; use labels
LABEL maintainer="maha" app="myjavaapp"

# No default/sample apps: smaller and safer
RUN rm -rf /usr/local/tomcat/webapps/*

# COPY for local files (ADD only when you need its extra features)
COPY login.war /usr/local/tomcat/webapps/login.war

# Run as non-root. Group 0 gets the owner's permissions, so any UID works
# (Kubernetes runAsNonRoot, and OpenShift's random UID).
RUN chgrp -R 0 /usr/local/tomcat && \
    chmod -R g=u /usr/local/tomcat
USER 1001

WORKDIR /usr/local/tomcat
EXPOSE 8080

# Settings are NOT baked in: Kubernetes injects APP_ENV, LOG_LEVEL, DB_USER, DB_PASSWORD
# from the ConfigMap/Secret, and mounts app.properties at /config.
CMD ["catalina.sh", "run"]
