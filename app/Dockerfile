FROM alpine:3.20

ARG IMAGE_TYPE=private-attestation
ENV IMAGE_TYPE=${IMAGE_TYPE}

WORKDIR /app

CMD ["sh", "-c", "echo 'private GHCR demo image (type: $IMAGE_TYPE)'"]
