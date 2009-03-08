class YouTubeG

  module Upload
    class UploadError < YouTubeG::Error; end
    class AuthenticationError < YouTubeG::Error; end
    
    # Implements video uploads/updates/deletions
    #
    #   require 'youtube_g'
    #   
    #   uploader = YouTubeG::Upload::VideoUpload.new("user", "pass", "dev-key")
    #   uploader.upload File.open("test.m4v"), :title => 'test',
    #                                        :description => 'cool vid d00d',
    #                                        :category => 'People',
    #                                        :keywords => %w[cool blah test]
    #
    class VideoUpload
      
      def initialize user, pass, dev_key, client_id = 'youtube_g'
        @user, @pass, @dev_key, @client_id = user, pass, dev_key, client_id
      end
      
      #
      # Upload "data" to youtube, where data is either an IO object or
      # raw file data.
      # The hash keys for opts (which specify video info) are as follows:
      #   :mime_type
      #   :filename
      #   :title
      #   :description
      #   :category
      #   :keywords
      #   :private
      # Specifying :private will make the video private, otherwise it will be public.
      #
      # When one of the fields is invalid according to YouTube,
      # an UploadError will be raised. Its message contains a list of newline separated
      # errors, containing the key and its error code.
      # 
      # When the authentication credentials are incorrect, an AuthenticationError will be raised.
      def upload data, opts = {}
        @opts = { :mime_type => 'video/mp4',
                  :title => '',
                  :description => '',
                  :category => '',
                  :keywords => [] }.merge(opts)
        
        @opts[:filename] ||= generate_uniq_filename_from(data)
        
        post_body_io = generate_upload_io(video_xml, data)
        
        upload_headers = authorization_headers.merge({
            "Slug"           => "#{@opts[:filename]}",
            "Content-Type"   => "multipart/related; boundary=#{boundary}",
            "Content-Length" => "#{post_body_io.expected_length}", # required per YouTube spec
          # "Transfer-Encoding" => "chunked" # We will stream instead of posting at once
        })
        
        path = '/feeds/api/users/%s/uploads' % @user
        
        resp = YouTubeG.transport.send_req(
          :method => 'post',
          :host => uploads_url,
          :body => post_body_io,
          :headers => upload_headers,
          :path => path
        )
        
        raise_on_faulty_response(response)
        return uploaded_video_id_from(response.body)
      end
      
      # Updates a video in YouTube.  Requires:
      #   :title
      #   :description
      #   :category
      #   :keywords
      # The following are optional attributes:
      #   :private
      # When the authentication credentials are incorrect, an AuthenticationError will be raised.
      def update(video_id, options)
        @opts = options
        
        update_header = authorization_headers.merge({
          "Content-Type"   => "application/atom+xml",
          "Content-Length" => "#{update_body.length}",
        })
        
        update_url = "/feeds/api/users/#{@user}/uploads/#{video_id}"
        response = YouTubeG.transport.send_req(:method => 'put', :path => update_url, :headers => update_header, :body => video_xml)
        raise_on_faulty_response(response)
        return YouTubeG::Parser::VideoFeedParser.new(response.body).parse
      end
      
      # Delete a video on YouTube
      def delete(video_id)
        delete_header = authorization_headers.merge({
          "Content-Type"   => "application/atom+xml",
          "Content-Length" => "0",
        })
        
        delete_url = "/feeds/api/users/#{@user}/uploads/#{video_id}"
        YouTubeG.transport.delete_req(:path => delete_url, :headers => delete_header)
        raise_on_faulty_response(response)
        true
      end
      
      private
      
      def uploads_url
        ["uploads", base_url].join('.')
      end
      
      def base_url
        "gdata.youtube.com"
      end
      
      # TODO: if we do not peek into the files we upload, it's not possible to guarantee 
      # that the boundary is not encountered. However, in this case we prefer that to scanning
      # 9 megs of files for a substring.
      # Were the authors of the MIME spec not so unfortunately blind, they would have implemented
      # Content-Length or Part-Length as an alternative to boundaries for raw data parts
      def boundary 
        "An43094fu"
      end
      
      def authorization_headers
        {
          "Authorization"  => "GoogleLogin auth=#{auth_token}",
          "X-GData-Client" => "#{@client_id}",
          "X-GData-Key"    => "key=#{@dev_key}"
        }
      end
      
      def parse_upload_error_from(string)
        REXML::Document.new(string).elements["//errors"].inject('') do | all_faults, error|
          location = error.elements["location"].text[/media:group\/media:(.*)\/text\(\)/,1]
          code = error.elements["code"].text
          all_faults + sprintf("%s: %s\n", location, code)
        end
      end
      
      def raise_on_faulty_response(response)
        if response.code.to_i == 403
          raise AuthenticationError, response.body[/<TITLE>(.+)<\/TITLE>/, 1]
        elsif response.code.to_i != 200
          raise UploadError, parse_upload_error_from(response.body)
        end 
      end
      
      def uploaded_video_id_from(string)
        xml = REXML::Document.new(string)
        xml.elements["//id"].text[/videos\/(.+)/, 1]
      end
      
      # If data can be read, use the first 1024 bytes as filename. If data
      # is a file, use path. If data is a string, checksum it
      def generate_uniq_filename_from(data)
        if data.respond_to?(:path)
          Digest::MD5.hexdigest(data.path)
        elsif data.respond_to?(:read)
          chunk = data.read(1024)
          data.rewind
          Digest::MD5.hexdigest(chunk)
        else
          Digest::MD5.hexdigest(data)
        end
      end
      
      def auth_token
        @auth_token ||= begin
          response.body = YouTubeG.transport.post_req(
            :ssl => true, :host => 'www.google.com',
            :body => "Email=#{YouTubeG.esc @user}&Passwd=#{YouTubeG.esc @pass}&service=youtube&source=#{YouTubeG.esc @client_id}",
            :path => "/youtube/accounts/ClientLogin"
          )
          raise UploadError, response.body[/Error=(.+)/,1] if response.code.to_i != 200
          @auth_token = response.body[/Auth=(.+)/, 1]
        end
      end
      
      # TODO: isn't there a cleaner way to output top-notch XML without requiring stuff all over the place?
      def video_xml
        b = Builder::XML.new
        b.instruct!
        b.entry(:xmlns => "http://www.w3.org/2005/Atom", 'xmlns:media' => "http://search.yahoo.com/mrss/", 'xmlns:yt' => "http://gdata.youtube.com/schemas/2007") do | m |
          m.tag!("media:group") do | mg |
            mg.tag!("media:title", :type => "plain") { @opts[:title] }
            mg.tag!("media:description", :type => "plain") { @opts[:description] }
            mg.tag!("media:keywords") { @opts[:keywords].join(",") }
            mg.tag!('media:category', :scheme => "http://gdata.youtube.com/schemas/2007/categories.cat") { @opts[:category] }
            mg.tag!('yt:private') if @opts[:private]
          end
        end.to_s
      end
      
      def generate_upload_io(video_xml, data)
        post_body = [
          "--#{boundary}\r\n",
          "Content-Type: application/atom+xml; charset=UTF-8\r\n\r\n",
          video_xml,
          "\r\n--#{boundary}\r\n",
          "Content-Type: #{@opts[:mime_type]}\r\nContent-Transfer-Encoding: binary\r\n\r\n",
          data,
          "\r\n--#{boundary}--\r\n",
        ]
        
        # Use Greedy IO to not be limited by 1K chunks
        YouTubeG::GreedyChainIO.new(post_body)
      end

    end
  end
end