package com.lab.scoring;

import com.lab.scoring.config.FailureModes;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.context.properties.EnableConfigurationProperties;

@SpringBootApplication
@EnableConfigurationProperties(FailureModes.class)
public class ScoringServiceApplication {

    public static void main(String[] args) {
        SpringApplication.run(ScoringServiceApplication.class, args);
    }
}
