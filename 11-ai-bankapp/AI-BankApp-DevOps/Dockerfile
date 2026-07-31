# Jenkins builds the JAR before invoking BuildKit. Keeping Maven out of the
# image build avoids a second, unverified dependency resolution.
FROM eclipse-temurin:21-jre-alpine
WORKDIR /app

# Pull latest security patches for OS libraries
RUN apk update && apk upgrade --no-cache

# Create a non-root user for security (Alpine uses addgroup/adduser instead of groupadd/useradd)
RUN addgroup -S devsecops && adduser -S -G devsecops devsecops
USER devsecops

# Copy only the artifact produced by the pipeline's Maven stage.
COPY target/bankapp-*.jar app.jar

EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
