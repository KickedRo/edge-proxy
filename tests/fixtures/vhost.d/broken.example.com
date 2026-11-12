# Test fixture: a per-vhost snippet that repeats a directive nginx-proxy's template already generates in the
# server block (the HTTPS listener). nginx refuses it ("a duplicate listen"), which is what the
# split-layout smoke test uses to prove that a broken snippet is caught by `nginx -t`.
# The test installs this file as vhost.d/broken.example.com, the name nginx-proxy includes for that vhost.
listen 443 ssl;
