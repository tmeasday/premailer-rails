# subclass Premailer to make it behave in a sensible way when rails is involved
class PremailerRails < Premailer
  def load_html(string)
    Hpricot(string)
  end
  
  def self.resolve_link(path, base_path)
    # don't escape mailtos
    if path =~ /^mailto:/
      path
    # ie base path is the full html string, we need to locate the local file
    elsif base_path.kind_of?(String) and base_path !~ /^(http[s]?|ftp):\/\//i
      'public' + path

    # if it is a css file and we have a real base path, we are absolutizing.
    # we don't want to do that to local css files
    elsif path =~ /(^.*.css)(\?.*)$/ 
      $1 # strip off the etag
    else
      super(path, base_path)
    end
  end
end