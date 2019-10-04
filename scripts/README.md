# Elastic OOTB Scripts

Script for the Elastic Stack Out-of-the-Box (OOTB) demonstration. 

## Getting Started

See accompanying slides pdf for details on their usage/prupose. (TODO)

### Prerequisites

You will need:
 - An Elastic Cloud (trial) account on https://cloud.elastic.co
 - The slides pdf as a step by step guide
 - At least one VM running: Debian or CentOS (should also work for Ubunto or RHEL)
 - A normal user that can sudo
 - The lsb_release and curl commands installed (see scripts for details)

### Installing

Create and cd to a suitable director (under a normal user), and git clone this repository.
Then cd to elastic-ootb/scripts and execute the scripts as given in the slides.

## Running the tests

You can use the _reset-ootb.sh script to remove everything the other scripts installed/created.
Use this with care it may remove more than you want it to, it may also leave some things behind.
This script is inteded for repeat testing of the other scripts. VM snapshot would be a better alternative to _reset-ootb.sh.

## Deployment

These scripts are for demonstration purposes only, they do not follow all production deployment
recommendations. Most notably they use the 'elastic' superuser and not a dedicated beats user.

## Contributing

Get in touch with me.

## Versioning

No versioning of the script themselves, use as-is. They are writen in a way that they can be used with any post 7.x deployment.

## Authors

Thorben Jändling <thorbenj@users.noreply.github.com>

## License

See Licence in the project root dir.

## Acknowledgments

Many colleagues at Elastic.co!
