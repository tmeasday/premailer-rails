# Include hook code here
require 'premailer'

ActionMailer::Base.send :include, PremailerExtensions