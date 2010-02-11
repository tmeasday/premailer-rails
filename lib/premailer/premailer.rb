#!/usr/bin/ruby
#
# Premailer by Alex Dunae (dunae.ca, e-mail 'code' at the same domain), 2008
# Version 1.5.0

ENV["GEM_PATH"] = "/home/alexdunae/.gems:/usr/lib/ruby/gems/1.8"

$LOAD_PATH.unshift(File.expand_path(File.dirname(__FILE__), ''))

require 'rubygems'
require 'yaml'
require 'open-uri'
require 'hpricot'
require 'css_parser'

require 'html_to_plain_text'

# Premailer processes HTML and CSS to improve e-mail deliverability.
#
# Premailer's main function is to render all CSS as inline <tt>style</tt> attributes using
# the CssParser. It can also convert relative links to absolute links and check the 'safety' of 
# CSS properties against a CSS support chart.
#
# = Example
#
#  premailer = Premailer.new(html_file, :warn_level => Premailer::Warnings::SAFE)
#  premailer.parse!
#  puts premailer.warnings.length.to_s + ' warnings found'
class Premailer
  include HtmlToPlainText
  include CssParser

  CLIENT_SUPPORT_FILE = File.dirname(__FILE__) + '/../misc/client_support.yaml'

  RE_UNMERGABLE_SELECTORS = /(\:(visited|active|hover|focus|after|before|selection|target|first\-(line|letter))|^\@)/i
  URL_RE = /url\(['"](.*)['"]\)/
  
  
  # should also exclude :first-letter, etc...

  # URI of the HTML file used
  attr_reader   :html_file            

  module Warnings
    NONE = 0
    SAFE = 1
    POOR = 2
    RISKY = 3
  end
  include Warnings

  WARN_LABEL = %w(NONE SAFE POOR RISKY)

  # Create a new Premailer object.
  #
  # +uri+ is the URL of the HTML file to process. Should be a string.
  #
  # ==== Options
  # [+line_length+] Line length used by to_plain_text. Boolean, default is 65.
  # [+warn_level+] What level of CSS compatibility warnings to show (see Warnings).
  # [+link_query_string+] A string to append to every <a href=""> link.
  def initialize(uri, options = {})
    @options = {:warn_level => Warnings::SAFE, :line_length => 65, :link_query_string => nil, :base_url => nil}.merge(options)
    @html_file = uri

    
    @is_local_file = true
    if uri =~ /^(http|https|ftp)\:\/\//i
      @is_local_file = false
    end


    @css_warnings = []

    @css_parser = CssParser::Parser.new({:absolute_paths => true,
                                         :import => true,
                                         :io_exceptions => false
                                        })
    
    @doc, @html_charset = load_html(@html_file)
    if @is_local_file and @options[:base_url]
      @doc = convert_inline_links(@doc, @options[:base_url])
    elsif not @is_local_file
      @doc = convert_inline_links(@doc, @html_file)
    end
    load_css_from_html!
  end

  # Array containing a hash of CSS warnings.
  def warnings
    return [] if @options[:warn_level] == Warnings::NONE
    @css_warnings = check_client_support if @css_warnings.empty?
    @css_warnings
  end

  # Returns the original HTML as a string.
  def to_s
    @doc.to_html
  end

  # Returns the document with all HTML tags removed.
  def to_plain_text
    html_src = ''
    begin
      html_src = @doc.search("body").innerHTML
    rescue
      html_src = @doc.to_html
    end
    convert_to_text(html_src, @options[:line_length], @html_charset)
  end

  # Merge CSS into the HTML document.
  #
  # Returns a string.
  def to_inline_css
    doc = @doc
    unmergable_rules = CssParser::Parser.new
    
    # Give all styles already in style attributes a specificity of 1000 
    # per http://www.w3.org/TR/CSS21/cascade.html#specificity
    doc.search("*[@style]").each do |el| 
      el['style'] = '[SPEC=1000[' + el.attributes['style'] + ']]'
    end

    # Iterate through the rules and merge them into the HTML
    @css_parser.each_selector(:all) do |selector, declaration, specificity|
      # TOM ADDED: absolutize the urls inside declarations
      declaration.sub!(URL_RE) do 
        "url('#{self.class.resolve_link($1, @options[:base_url])}')"
      end
      
      # Save un-mergable rules separately
      selector.gsub!(/:link([\s]|$)+/i, '')

      # Convert element names to lower case
      selector.gsub!(/([\s]|^)([\w]+)/) {|m| $1.to_s + $2.to_s.downcase }

      if selector =~ RE_UNMERGABLE_SELECTORS
        unmergable_rules.add_rule_set!(RuleSet.new(selector, declaration))
      else
        
        doc.search(selector) do |el|
          if el.elem?
            # Add a style attribute or append to the existing one  
            block = "[SPEC=#{specificity}[#{declaration}]]"
            el['style'] = (el.attributes['style'] ||= '') + ' ' + block
          end
        end
      end
    end

    # Read <style> attributes and perform folding
    doc.search("*[@style]").each do |el|
      style = el.attributes['style'].to_s
      
      declarations = []

      style.scan(/\[SPEC\=([\d]+)\[(.[^\]\]]*)\]\]/).each do |declaration|
        rs = RuleSet.new(nil, declaration[1].to_s, declaration[0].to_i)
        declarations << rs
      end

      # Perform style folding and save
      merged = CssParser.merge(declarations)

      el['style'] = Premailer.escape_string(merged.declarations_to_s)
    end

    doc = write_unmergable_css_rules(doc, unmergable_rules)
    
    #doc = add_body_imposter(doc)
    
    doc.to_html
  end


protected  
  # Load the HTML file and convert it into an Hpricot document.
  #
  # Returns an Hpricot document and a string with the HTML file's character set.
  def load_html(uri)
      Hpricot(open(uri))
  end

  # Load CSS included in <tt>style</tt> and <tt>link</tt> tags from an HTML document.
  def load_css_from_html!
    if tags = @doc.search("link[@rel='stylesheet'], style")
      tags.each do |tag|
        if tag.to_s.strip =~ /^\<link/i and tag.attributes['href']
          if media_type_ok?(tag.attributes['media'])
            link_uri = self.class.resolve_link(tag.attributes['href'].to_s, @html_file)
            if @is_local_file
              css_block = ''
              File.open(link_uri, "r") do |file|
                while line = file.gets
                  css_block << line
                end
              end
              @css_parser.add_block!(css_block, {:base_uri => @html_file})
            else
              @css_parser.load_uri!(link_uri)
            end
          end
        elsif tag.to_s.strip =~ /^\<style/i          
          @css_parser.add_block!(tag.innerHTML, :base_uri => URI.parse(@html_file))
        end
      end
      tags.remove
    end
  end

  def media_type_ok?(media_types)
    return media_types.split(/[\s]+|,/).any? { |media_type| media_type.strip =~ /screen|handheld|all/i }
  rescue
    return true
  end

  # Create a <tt>style</tt> element with un-mergable rules (e.g. <tt>:hover</tt>) 
  # and write it into the <tt>body</tt>.
  #
  # <tt>doc</tt> is an Hpricot document and <tt>unmergable_css_rules</tt> is a Css::RuleSet.
  #
  # Returns an Hpricot document.
  def write_unmergable_css_rules(doc, unmergable_rules)
    styles = ''
    unmergable_rules.each_selector(:all, :force_important => true) do |selector, declarations, specificity|
      styles += "#{selector} { #{declarations} }\n"
    end    
    unless styles.empty?
      style_tag = "\n<style type=\"text/css\">\n#{styles}</style>\n"
      doc.search("head").append(style_tag)
    end
    doc
  end

  # Convert relative links to absolute links.
  #
  # Processes <tt>href</tt> <tt>src</tt> and <tt>background</tt> attributes 
  # as well as CSS <tt>url()</tt> declarations found in inline <tt>style</tt> attributes.
  #
  # <tt>doc</tt> is an Hpricot document and <tt>base_uri</tt> is either a string or a URI.
  #
  # Returns an Hpricot document.
  def convert_inline_links(doc, base_uri)
    base_uri = URI.parse(base_uri) unless base_uri.kind_of?(URI)

    ['href', 'src', 'background'].each do |attribute|
      
      tags = doc.search("*[@#{attribute}]")
      append_qs = @options[:link_query_string] ||= ''
      unless tags.empty?
        tags.each do |tag|
          unless tag.attributes[attribute] =~ /^(\{|\[|<|\#)/i
            if tag.attributes[attribute] =~ /^http/i
              begin
                merged = URI.parse(tag.attributes[attribute])
              rescue
                next
              end
            else
              begin
                merged = self.class.resolve_link(tag.attributes[attribute].to_s, base_uri)
              rescue
                begin
                  merged = self.class.resolve_link(URI.escape(tag.attributes[attribute].to_s), base_uri)
                #  merged = base_uri.merge(URI.escape(tag.attributes[attribute].to_s))
                rescue; end
              end
            end # end of relative urls only

            if tag.name =~ /^a$/i and not append_qs.empty?
              if merged.query
                merged.query = merged.query + '&' + append_qs
              else
                merged.query = append_qs
              end
            end
            tag[attribute] = merged.to_s
            #puts merged.inspect
          end # end of skipping special chars


        end # end of each tag
      end # end of empty
    end # end of attrs

    doc.search("*[@style]").each do |el|
      el['style'] = CssParser.convert_uris(el.attributes['style'].to_s, base_uri)
    end
    doc
  end

  def self.escape_string(str)
    str.gsub(/"/, "'")
  end
  
  def self.resolve_link(path, base_path)
    if base_path.kind_of?(URI)
      base_path.merge!(path)
      return Premailer.canonicalize(base_path)    
    elsif base_path.kind_of?(String) and base_path =~ /^(http[s]?|ftp):\/\//i
      base_uri = URI.parse(base_path)
      base_uri.merge!(path)
      return Premailer.canonicalize(base_uri)
    else

      return File.expand_path(path, File.dirname(base_path))
    end
  end

  # from http://www.ruby-forum.com/topic/140101
  def self.canonicalize(uri)
     u = uri.kind_of?(URI) ? uri : URI.parse(uri.to_s)
     u.normalize!
     newpath = u.path
     while newpath.gsub!(%r{([^/]+)/\.\./?}) { |match|
                $1 == '..' ? match : ''
              } do end
     newpath = newpath.gsub(%r{/\./}, '/').sub(%r{/\.\z}, '/')
     u.path = newpath
     u.to_s
  end



  def add_body_imposter(doc)
    newdoc = doc
    if body_tag = newdoc.at("body") and body_tag.attributes["style"]
      body_html = body_tag.inner_html
      body_tag.inner_html = "\n<div id=\"premailer_body_wrapper\">\n#{body_html}\n</div>\n"
      if body_tag.attributes["style"]
        newdoc.at("#premailer_body_wrapper")["style"] = body_tag.attributes["style"].to_s
        newdoc.at("body")["style"] = "margin: 0; padding: 0;"
      end
      
    end
    return newdoc
  rescue
    return doc
  end


  # Check <tt>CLIENT_SUPPORT_FILE</tt> for any CSS warnings
  def check_client_support
    @client_support = @client_support ||= YAML::load(File.open(CLIENT_SUPPORT_FILE))

    warnings = []
    properties = []
    
    # Get a list off CSS properties
    @doc.search("*[@style]").each do |el|
      style_url = el.attributes['style'].gsub(/([\w\-]+)[\s]*\:/i) do |s|
        properties.push($1)
      end
    end

    properties.uniq!

    property_support = @client_support['css_properties']
    properties.each do |prop|
      if property_support.include?(prop) and property_support[prop]['support'] >= @options[:warn_level]
        warnings.push({:message => "#{prop} CSS property", 
                       :level => WARN_LABEL[property_support[prop]['support']], 
                       :clients => property_support[prop]['unsupported_in'].join(', ')})
      end
    end

    @client_support['attributes'].each do |attribute, data|
      next unless data['support'] >= @options[:warn_level]
      if @doc.search("*[@#{attribute}]").length > 0
        warnings.push({:message => "#{attribute} HTML attribute", 
                       :level => WARN_LABEL[property_support[prop]['support']], 
                       :clients => property_support[prop]['unsupported_in'].join(', ')})
      end
    end

    @client_support['elements'].each do |element, data|
      next unless data['support'] >= @options[:warn_level]
      if @doc.search("element").length > 0
        warnings.push({:message => "#{element} HTML element", 
                       :level => WARN_LABEL[property_support[prop]['support']], 
                       :clients => property_support[prop]['unsupported_in'].join(', ')})
      end
    end




    
    return warnings
  end
end


