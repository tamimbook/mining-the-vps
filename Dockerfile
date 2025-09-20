FROM ubuntu:20.04
RUN apt-get update && apt-get install -y sudo curl
RUN useradd -m -s /bin/bash -G sudo minecraftuser && echo "minecraftuser:minecraft123" | chpasswd
USER minecraftuser
CMD ["/bin/bash"]
