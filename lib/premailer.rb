require 'premailer/premailer'

# These methods will be included into actionmailer, and thus extend the functionality.
module PremailerExtensions
  # preprocess the html view and attach it to the email as two separate parts
  # opts[:plain_text] = :from_html, :from_plain (from plain text), :none 
  def premail(opts = {})
    opts = {:plain_text => :from_plain, :warnings => false}.merge(opts)
    
    base_url = opts[:base_url] || ActionMailer::Base.default_url_options[:host]
    if base_url !~ /^(http[s]?|ftp):\/\//i
      base_url = 'http://' + base_url
    end
    
    template = template_root["#{mailer_name}/#{@template}.text.html.erb"]
    # return unless template
    
    noninline_html = render_message(template, @body)
    
    premailer = PremailerRails.new noninline_html, :base_url => base_url
    
    content_type    "multipart/alternative"
    
    
    if opts[:plain_text] == :from_html
      part 'text/plain' do |p|
        p.body = premailer.to_plain_text
      end
    elsif opts[:plain_text] == :from_plain
      template = template_root["#{mailer_name}/#{@template}.text.plain.erb"]
      part 'text/plain' do |p|
        p.body = render_message(template, @body)
      end      
    end
    
    # seems clients prefer the LAST part
    part 'text/html' do |p|
      p.body = premailer.to_inline_css
    end
    
    if opts[:warnings]
      premailer.warnings.each do |w|
        Rails.logger.warn w.inspect
      end
    end
  end
end